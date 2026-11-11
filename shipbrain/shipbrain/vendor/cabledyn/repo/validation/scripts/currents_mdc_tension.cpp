// SPDX-License-Identifier: Apache-2.0
// Line node tensions of a MoorDyn-C deck whose coupled points are held at their deck positions.
//
//   currents_mdc_tension <deck> <dt_out> <t_end> <out.csv>
//
// The system is initialised (the deck's TmaxIC sets the stationary initial condition) and stepped
// to t_end in steps of dt_out (MoorDyn-C sub-steps each at the deck's dtM). Output rows:
// "t,T0,...,TN" with Tk the tension magnitude MoorDyn_GetLineNodeTen reports at node k of line 1
// (the mean of the adjacent segment tensions at an interior node).
#include "MoorDyn2.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <vector>

int
main(int argc, char** argv)
{
	if (argc != 5) {
		std::cerr << "usage: currents_mdc_tension <deck> <dt_out> <t_end> <out.csv>" << std::endl;
		return 2;
	}
	const double dt_out = std::atof(argv[2]), t_end = std::atof(argv[3]);
	MoorDyn system = MoorDyn_Create(argv[1]);
	if (!system)
		return 3;
	unsigned int n_dof = 0, n_points = 0;
	if (MoorDyn_NCoupledDOF(system, &n_dof) != MOORDYN_SUCCESS ||
	    MoorDyn_GetNumberPoints(system, &n_points) != MOORDYN_SUCCESS)
		return 3;
	std::vector<double> x, dx(n_dof, 0.0);
	for (unsigned int i = 1; i <= n_points; i++) {
		MoorDynPoint point = MoorDyn_GetPoint(system, i);
		int type = 0;
		double pos[3];
		if (!point || MoorDyn_GetPointType(point, &type) != MOORDYN_SUCCESS ||
		    MoorDyn_GetPointPos(point, pos) != MOORDYN_SUCCESS)
			return 3;
		if (type == -1)
			x.insert(x.end(), pos, pos + 3);
	}
	if (x.size() != n_dof) {
		std::cerr << "the deck may couple points only" << std::endl;
		return 3;
	}
	std::vector<double> f(n_dof + 3, 0.0);
	if (MoorDyn_Init(system, x.data(), dx.data()) != MOORDYN_SUCCESS)
		return 4;
	MoorDynLine line = MoorDyn_GetLine(system, 1);
	unsigned int n = 0;
	if (!line || MoorDyn_GetLineN(line, &n) != MOORDYN_SUCCESS)
		return 5;
	FILE* out = std::fopen(argv[4], "w");
	if (!out)
		return 6;
	std::fprintf(out, "t");
	for (unsigned int k = 0; k <= n; k++)
		std::fprintf(out, ",T%u", k);
	std::fprintf(out, "\n");
	const long nstep = std::lround(t_end / dt_out);
	double t = 0.0;
	for (long s = 0; s <= nstep; s++) {
		if (s > 0) {
			double dt = dt_out;
			if (MoorDyn_Step(system, x.data(), dx.data(), f.data(), &t, &dt) != MOORDYN_SUCCESS)
				return 7;
		}
		std::fprintf(out, "%.10g", t);
		for (unsigned int k = 0; k <= n; k++) {
			double ten[3];
			MoorDyn_GetLineNodeTen(line, k, ten);
			std::fprintf(out, ",%.10g", std::sqrt(ten[0] * ten[0] + ten[1] * ten[1] + ten[2] * ten[2]));
		}
		std::fprintf(out, "\n");
	}
	std::fclose(out);
	MoorDyn_Close(system);
	return 0;
}
