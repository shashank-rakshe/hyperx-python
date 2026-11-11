// File: validation/scripts/bodies_mdc_runner.cpp
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
//
// MoorDyn-C reference runner for the bodies-and-rods validation suite.
//
// Steps a MoorDyn-C v2 deck and writes every body, rod, point and line-end quantity the
// suite scores, as a CSV with MoorDyn-F channel names. Coupled degrees of freedom follow
// analytic motions (constant + linear + quadratic + sinusoid per DOF) so that the same
// forcing can be tabulated exactly for the other codes.
//
// Build (MoorDyn-C source tree and build tree as arguments of the helper script
// bodies_run_moordyn_c.py, which compiles this file once):
//   g++ -O2 -std=c++17 -I<MoorDyn>/source -I<build>/source -I<MoorDyn>/source/Eigen
//       bodies_mdc_runner.cpp <build>/source/libmoordyn.dll -o bodies_mdc_runner.exe
//
// Usage:
//   bodies_mdc_runner deck.txt out.csv --tmax T --dtout D [--noic] [--scheme S]
//       [--dtm DT] [--cdt DT] [--motion file] [--bodyvel id vx vy vz wx wy wz]
//       [--settle T] [--nooutput]
//
// Motion file rows: dof c0 c1 c2 amp period phase_rad  (0-based coupled DOF index);
// x(t) = c0 + c1 t + c2 t^2 + amp sin(2 pi t / period + phase). DOFs without a row keep
// their initial deck value.
//
// --settle T: release protocol of the decay cases. The lines start from MoorDyn-C's own
// static equilibrium about the bodies held at their initial pose: a twin deck with every Free
// body made Fixed, TmaxIC = T and threshIC = 1e-7 is initialised with MoorDyn_Init (dynamic
// relaxation), and its
// line, Free point and free/pinned rod states (at rest) replace MoorDyn_Init_NoIC's deck
// positions and quasi-static catenary seed, which is not in
// equilibrium for a slack or seabed-touching line (V-D1b line 1: 3179 N against 3320 N).
//
// TenA/TenB are the magnitudes of the line-end node net force (MoorDyn-C Fnet), which is the
// force the line exerts on its attachment: the end-segment tension plus the end node's
// weight, buoyancy, drag and seabed load, without the end node's inertia.
//
// Timing (initialisation and march wall time) is printed to stderr as one JSON line.

#include "MoorDyn2.h"
#include "MoorDyn2.hpp"
#include "Body.hpp"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct DofMotion
{
	bool set = false;
	double c0 = 0, c1 = 0, c2 = 0, amp = 0, period = 1, phase = 0;
	double x(double t) const
	{
		return c0 + c1 * t + c2 * t * t +
		       amp * std::sin(2.0 * M_PI * t / period + phase);
	}
	double v(double t) const
	{
		const double w = 2.0 * M_PI / period;
		return c1 + 2.0 * c2 * t + amp * w * std::cos(w * t + phase);
	}
};

struct BodyVel
{
	int id;
	double v[6];
};

int
fail(const char* msg)
{
	std::fprintf(stderr, "bodies_mdc_runner: %s\n", msg);
	return 1;
}

// Write the --settle twin: every Free body of the BODIES table made Fixed, TmaxIC set to T,
// threshIC 1e-7.
bool
write_settle_twin(const char* deck, const std::string& twin, double tmaxic)
{
	std::ifstream in(deck);
	if (!in)
		return false;
	std::ofstream out(twin);
	std::string line, section;
	bool has_tmaxic = false;
	while (std::getline(in, line)) {
		if (line.rfind("---", 0) == 0) {
			section = line;
			out << line << "\n";
			continue;
		}
		std::istringstream ss(line);
		std::vector<std::string> tok;
		std::string w;
		while (ss >> w)
			tok.push_back(w);
		if (section.find("BODIES") != std::string::npos && tok.size() > 2 && tok[1] == "Free") {
			line.replace(line.find("Free"), 4, "Fixed");
		} else if (tok.size() >= 2 && (tok[1] == "TmaxIC" || tok[1] == "TMaxIC")) {
			line = std::to_string(tmaxic) + "  TmaxIC";
			has_tmaxic = true;
		} else if (tok.size() >= 2 && tok[1] == "threshIC") {
			line = "1e-7  threshIC"; // settle well below the deck's release tolerance
		}
		out << line << "\n";
	}
	return has_tmaxic && bool(out);
}

} // namespace

int
main(int argc, char** argv)
{
	if (argc < 3)
		return fail("usage: deck out.csv --tmax T --dtout D [options]");
	const char* deck = argv[1];
	const char* outpath = argv[2];
	double tmax = -1, dtout = -1, dtm = -1, cdt = -1, settle = 0;
	bool noic = false, nooutput = false;
	std::string scheme, motion;
	std::vector<BodyVel> bodyvels;
	for (int i = 3; i < argc; i++) {
		std::string a = argv[i];
		auto need = [&](int n) {
			if (i + n >= argc) {
				std::fprintf(stderr, "missing value for %s\n", a.c_str());
				std::exit(1);
			}
		};
		if (a == "--tmax") { need(1); tmax = atof(argv[++i]); }
		else if (a == "--dtout") { need(1); dtout = atof(argv[++i]); }
		else if (a == "--dtm") { need(1); dtm = atof(argv[++i]); }
		else if (a == "--cdt") { need(1); cdt = atof(argv[++i]); }
		else if (a == "--noic") noic = true;
		else if (a == "--nooutput") nooutput = true;
		else if (a == "--settle") { need(1); settle = atof(argv[++i]); }
		else if (a == "--scheme") { need(1); scheme = argv[++i]; }
		else if (a == "--motion") { need(1); motion = argv[++i]; }
		else if (a == "--bodyvel") {
			need(7);
			BodyVel b;
			b.id = atoi(argv[++i]);
			for (int k = 0; k < 6; k++)
				b.v[k] = atof(argv[++i]);
			bodyvels.push_back(b);
		} else {
			std::fprintf(stderr, "unknown argument %s\n", a.c_str());
			return 1;
		}
	}
	if (tmax <= 0 || dtout <= 0)
		return fail("--tmax and --dtout must be positive");
	if (cdt <= 0)
		cdt = dtout;
	const long nsub = std::lround(dtout / cdt);
	if (nsub < 1 || std::fabs(nsub * cdt - dtout) > 1e-9 * dtout)
		return fail("--dtout must be an integer multiple of --cdt");

	auto tc0 = std::chrono::steady_clock::now();
	MoorDyn s = MoorDyn_Create(deck);
	if (!s)
		return fail("MoorDyn_Create failed");
	MoorDyn_SetVerbosity(s, MOORDYN_ERR_LEVEL);
	if (!scheme.empty() && MoorDyn_SetTimeScheme(s, scheme.c_str()))
		return fail("unknown time scheme");
	if (dtm > 0 && MoorDyn_SetDt(s, dtm))
		return fail("MoorDyn_SetDt failed");

	for (const auto& bv : bodyvels) {
		auto bodies = ((moordyn::MoorDyn*)s)->GetBodies();
		if (bv.id < 1 || bv.id > (int)bodies.size())
			return fail("--bodyvel names an unknown body");
		moordyn::Body* b = bodies[bv.id - 1];
		for (int k = 0; k < 6; k++)
			b->v6[k] = bv.v[k];
	}

	unsigned int ndof = 0;
	MoorDyn_NCoupledDOF(s, &ndof);
	std::vector<DofMotion> mot(ndof);
	std::vector<double> x(ndof + 1, 0.0), xd(ndof + 1, 0.0), f(ndof + 1, 0.0);
	if (!motion.empty()) {
		std::ifstream in(motion);
		if (!in)
			return fail("cannot open motion file");
		std::string line;
		while (std::getline(in, line)) {
			if (line.empty() || line[0] == '#')
				continue;
			std::istringstream ss(line);
			int dof;
			DofMotion m;
			if (!(ss >> dof >> m.c0 >> m.c1 >> m.c2 >> m.amp >> m.period >> m.phase))
				return fail("bad motion row");
			if (dof < 0 || dof >= (int)ndof)
				return fail("motion DOF index out of range");
			m.set = true;
			mot[dof] = m;
		}
	}
	for (unsigned int k = 0; k < ndof; k++)
		if (!mot[k].set)
			return fail("every coupled DOF needs a motion row");
	// Initialise with the hosts at rest at their t = 0 position: MoorDyn-C's dynamic-relaxation
	// IC extrapolates coupled points with the given velocity, which would move them during the IC.
	for (unsigned int k = 0; k < ndof; k++) {
		x[k] = mot[k].x(0.0);
		xd[k] = 0.0;
	}

	int e = noic ? MoorDyn_Init_NoIC(s, x.data(), xd.data())
	             : MoorDyn_Init(s, x.data(), xd.data());
	if (e)
		return fail("MoorDyn_Init failed");
	if (settle > 0) {
		// Settle the lines about the held bodies with MoorDyn-C's own dynamic relaxation: a
		// twin deck with every Free body made Fixed is initialised with MoorDyn_Init
		// (TmaxIC = settle), and its line states replace the NoIC catenary seed.
		const std::string twin = std::string(outpath) + ".settle.txt";
		if (!write_settle_twin(deck, twin, settle))
			return fail("cannot write the settle twin deck");
		MoorDyn s2 = MoorDyn_Create(twin.c_str());
		if (!s2)
			return fail("MoorDyn_Create failed on the settle twin");
		MoorDyn_SetVerbosity(s2, MOORDYN_ERR_LEVEL);
		if (MoorDyn_Init(s2, x.data(), xd.data()))
			return fail("MoorDyn_Init failed on the settle twin");
		moordyn::MoorDyn* sys = (moordyn::MoorDyn*)s;
		moordyn::MoorDyn* sys2 = (moordyn::MoorDyn*)s2;
		auto* ts = sys->GetTimeScheme();
		auto* ts2 = sys2->GetTimeScheme();
		moordyn::state::State cur = ts->GetState(0);
		moordyn::state::State st2 = ts2->GetState(0);
		const auto lines = sys->GetLines();
		const auto lines2 = sys2->GetLines();
		if (lines.size() != lines2.size())
			return fail("settle twin has a different line count");
		for (size_t k = 0; k < lines.size(); k++) {
			auto v = cur.get(lines[k]);
			v = st2.get(lines2[k]);
			v.rightCols(3).setZero(); // start at rest
		}
		// Free points and free/pinned rods settle with the lines: their relaxed states replace
		// the deck positions (held objects have no state and are skipped).
		const auto pts = sys->GetPoints();
		const auto pts2 = sys2->GetPoints();
		for (size_t k = 0; k < pts.size() && k < pts2.size(); k++) {
			try {
				auto v = cur.get(pts[k]);
				v = st2.get(pts2[k]);
				v.rightCols(3).setZero();
			} catch (...) {
			}
		}
		const auto rods = sys->GetRods();
		const auto rods2 = sys2->GetRods();
		for (size_t k = 0; k < rods.size() && k < rods2.size(); k++) {
			try {
				auto v = cur.get(rods[k]);
				v = st2.get(rods2[k]);
				v.rightCols(6).setZero();
			} catch (...) {
			}
		}
		ts->SetState(cur, 0);
		MoorDyn_Close(s2);
		std::remove(twin.c_str());
	}
	auto tc1 = std::chrono::steady_clock::now();

	unsigned int nb = 0, nr = 0, np = 0, nl = 0;
	MoorDyn_GetNumberBodies(s, &nb);
	MoorDyn_GetNumberRods(s, &nr);
	MoorDyn_GetNumberPoints(s, &np);
	MoorDyn_GetNumberLines(s, &nl);

	FILE* out = nooutput ? nullptr : std::fopen(outpath, "w");
	if (!nooutput && !out)
		return fail("cannot open output file");
	auto header = [&]() {
		std::fprintf(out, "Time");
		for (unsigned int b = 1; b <= nb; b++)
			for (const char* c : { "Px", "Py", "Pz", "Rx", "Ry", "Rz", "Vx", "Vy",
			                       "Vz", "RVx", "RVy", "RVz" })
				std::fprintf(out, ",Body%u%s", b, c);
		for (unsigned int r = 1; r <= nr; r++) {
			unsigned int N;
			MoorDyn_GetRodN(MoorDyn_GetRod(s, r), &N);
			for (const char* c : { "Px", "Py", "Pz" })
				std::fprintf(out, ",Rod%u%s", r, c);
			for (const char* c : { "Px", "Py", "Pz" })
				std::fprintf(out, ",Rod%uN%u%s", r, N, c);
		}
		for (unsigned int p = 1; p <= np; p++)
			for (const char* c : { "Px", "Py", "Pz", "Fx", "Fy", "Fz" })
				std::fprintf(out, ",Point%u%s", p, c);
		for (unsigned int l = 1; l <= nl; l++)
			std::fprintf(out, ",TenA%u,TenB%u", l, l);
		std::fprintf(out, "\n");
	};
	auto row = [&](double t) {
		std::fprintf(out, "%.6f", t);
		for (unsigned int b = 1; b <= nb; b++) {
			MoorDynBody B = MoorDyn_GetBody(s, b);
			double p[3], a[3], v[3], w[3];
			MoorDyn_GetBodyPos(B, p);
			MoorDyn_GetBodyAngle(B, a);
			MoorDyn_GetBodyVel(B, v);
			MoorDyn_GetBodyAngVel(B, w);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", p[k]);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", a[k] * 180.0 / M_PI);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", v[k]);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", w[k]);
		}
		for (unsigned int r = 1; r <= nr; r++) {
			MoorDynRod R = MoorDyn_GetRod(s, r);
			unsigned int N;
			MoorDyn_GetRodN(R, &N);
			double a[3], b[3];
			MoorDyn_GetRodNodePos(R, 0, a);
			MoorDyn_GetRodNodePos(R, N, b);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", a[k]);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", b[k]);
		}
		for (unsigned int p = 1; p <= np; p++) {
			MoorDynPoint P = MoorDyn_GetPoint(s, p);
			double q[3], F[3] = { 0, 0, 0 };
			MoorDyn_GetPointPos(P, q);
			int ptype = 0;
			MoorDyn_GetPointType(P, &ptype);
			if (ptype == 1) {
				// Fixed point: MoorDyn-C does not evaluate its net force, so report the
				// load the bound line ends exert on it (sum of end-node net forces).
				unsigned int na = 0;
				MoorDyn_GetPointNAttached(P, &na);
				for (unsigned int i = 0; i < na; i++) {
					MoorDynLine L;
					int end;
					MoorDyn_GetPointAttached(P, i, &L, &end);
					unsigned int N;
					MoorDyn_GetLineN(L, &N);
					double fe[3];
					MoorDyn_GetLineNodeForce(L, end == 0 ? 0 : N, fe);
					for (int k = 0; k < 3; k++)
						F[k] += fe[k];
				}
			} else {
				MoorDyn_GetPointForce(P, F);
			}
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", q[k]);
			for (int k = 0; k < 3; k++)
				std::fprintf(out, ",%.10e", F[k]);
		}
		for (unsigned int l = 1; l <= nl; l++) {
			MoorDynLine L = MoorDyn_GetLine(s, l);
			unsigned int N;
			MoorDyn_GetLineN(L, &N);
			double fa[3], fb[3];
			MoorDyn_GetLineNodeForce(L, 0, fa);
			MoorDyn_GetLineNodeForce(L, N, fb);
			std::fprintf(out, ",%.10e,%.10e",
			             std::sqrt(fa[0] * fa[0] + fa[1] * fa[1] + fa[2] * fa[2]),
			             std::sqrt(fb[0] * fb[0] + fb[1] * fb[1] + fb[2] * fb[2]));
		}
		std::fprintf(out, "\n");
	};

	// A 1e-9 s start-up step evaluates the right-hand side once, so the t = 0 row carries
	// the initial line-end forces (MoorDyn-C leaves them zero until the first step).
	double t = 0.0;
	{
		for (unsigned int d = 0; d < ndof; d++) {
			x[d] = mot[d].x(0.0);
			xd[d] = mot[d].v(0.0);
		}
		double dt0 = 1e-9;
		if (MoorDyn_Step(s, x.data(), xd.data(), f.data(), &t, &dt0))
			return fail("start-up step failed");
		t = 0.0;
	}
	if (out) {
		header();
		row(0.0);
	}
	const long nout = std::lround(tmax / dtout);
	for (long k = 1; k <= nout; k++) {
		for (long j = 0; j < nsub; j++) {
			for (unsigned int d = 0; d < ndof; d++) {
				x[d] = mot[d].x(t);
				xd[d] = mot[d].v(t);
			}
			double dt = cdt;
			if (MoorDyn_Step(s, x.data(), xd.data(), f.data(), &t, &dt)) {
				std::fprintf(stderr, "Step failed at t = %g\n", t);
				if (out)
					std::fclose(out);
				return 4;
			}
		}
		t = k * dtout; // remove accumulated round-off of the coupling steps
		if (out)
			row(t);
	}
	auto tc2 = std::chrono::steady_clock::now();
	std::fprintf(stderr,
	             "{\"init_s\": %.6f, \"march_s\": %.6f}\n",
	             std::chrono::duration<double>(tc1 - tc0).count(),
	             std::chrono::duration<double>(tc2 - tc1).count());
	if (out)
		std::fclose(out);
	MoorDyn_Close(s);
	return 0;
}
