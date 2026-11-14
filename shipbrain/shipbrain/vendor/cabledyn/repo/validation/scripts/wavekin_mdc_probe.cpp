// SPDX-License-Identifier: Apache-2.0
// Sample the MoorDyn-C water kinematics of a deck at given points and times.
//
//   wavekin_mdc_probe <deck> <points> <out.csv>
//
// <points> rows: "t x y z", in non-decreasing t. The deck's system is initialised (TmaxIC 0) with
// its coupled points held at their deck positions, stepped to each time, and
// MoorDyn_GetWavesKin is evaluated there. Output rows: "t,x,y,z,zeta,ux,uy,uz,ax,ay,az".
#include "MoorDyn2.h"

#include <cstdio>
#include <fstream>
#include <iostream>
#include <vector>

int
main(int argc, char** argv)
{
	if (argc != 4) {
		std::cerr << "usage: wavekin_mdc_probe <deck> <points> <out.csv>" << std::endl;
		return 2;
	}
	std::ifstream pin(argv[2]);
	std::vector<double> rows;
	double v;
	while (pin >> v)
		rows.push_back(v);
	if (rows.empty() || rows.size() % 4 != 0) {
		std::cerr << "points file must hold rows of t x y z" << std::endl;
		return 2;
	}
	MoorDyn system = MoorDyn_Create(argv[1]);
	if (!system)
		return 3;
	unsigned int n_dof = 0, n_points = 0;
	if (MoorDyn_NCoupledDOF(system, &n_dof) != MOORDYN_SUCCESS ||
	    MoorDyn_GetNumberPoints(system, &n_points) != MOORDYN_SUCCESS)
		return 3;
	// the coupled points held at their deck positions
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
		std::cerr << "the probe deck may couple points only" << std::endl;
		return 3;
	}
	std::vector<double> f(n_dof + 3, 0.0);
	if (MoorDyn_Init(system, x.data(), dx.data()) != MOORDYN_SUCCESS)
		return 4;
	MoorDynWaves waves = MoorDyn_GetWaves(system);
	if (!waves)
		return 5;
	FILE* out = std::fopen(argv[3], "w");
	if (!out)
		return 6;
	std::fprintf(out, "t,x,y,z,zeta,ux,uy,uz,ax,ay,az\n");
	double t = 0.0;
	for (size_t i = 0; i < rows.size(); i += 4) {
		const double target = rows[i];
		if (target > t) {
			double dt = target - t;
			if (MoorDyn_Step(system, x.data(), dx.data(), f.data(), &t, &dt) != MOORDYN_SUCCESS)
				return 7;
		}
		double U[3], Ud[3], zeta, pdyn;
		if (MoorDyn_GetWavesKin(
		        waves, rows[i + 1], rows[i + 2], rows[i + 3], U, Ud, &zeta, &pdyn, nullptr) !=
		    MOORDYN_SUCCESS)
			return 8;
		std::fprintf(out,
		             "%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n",
		             t,
		             rows[i + 1],
		             rows[i + 2],
		             rows[i + 3],
		             zeta,
		             U[0],
		             U[1],
		             U[2],
		             Ud[0],
		             Ud[1],
		             Ud[2]);
	}
	std::fclose(out);
	MoorDyn_Close(system);
	return 0;
}
