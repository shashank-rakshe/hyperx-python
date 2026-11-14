import os, sys, tempfile
import pytest
from shipbrain import agent, knowledge


@pytest.fixture(scope='module')
def T(tmp_path_factory):
    return agent.Tools(str(tmp_path_factory.mktemp('rt')), knowledge.load(None), allow_code=True)


QUERIES = [
    ('write a python script that loops over plate thicknesses 8 to 20 and prints the weight', 'python_run'),
    ('use python to plot stress against load from my csv', 'python_run'),
    ('make a 3d step file of a flange with 8 bolt holes', 'cadquery_build'),
    ('cadquery script for a bracket', 'cadquery_build'),
    ('call a function from my matlab folder', 'code_call'),
    ('which mcp servers are connected', 'mcp_tools'),
    ('build a surrogate model of this analysis', 'surrogate_build'),
    ('always show me mm and MPa, set my profile', 'set_profile'),
    ('save these steps as a workflow', 'add_skill'),
    ('forget that wrong memory', 'memory_feedback'),
    ('run calculix on this inp', 'solve_calculix'),
    ('clean up the geometry of this step file, there are sliver faces', 'geometry_clean'),
    ('extract the pipe centerlines from the cad', 'pipe_extract'),
    ('explain the results of this analysis', 'result_insight'),
    ('compare the mesh with the drawing', 'compare_mesh_drawing'),
    ('make a 3d model from this 2d drawing', 'drawing_to_3d'),
    ('count the receptacles on the electrical drawing', 'drawing_takeoff'),
    ('check the setup before I solve', 'setup_check'),
    ('read this ocx ship model', 'ocx_read'),
    ('how many users can the server handle, tokens per second', 'serving_sim'),
    ('read this pdf specification', 'parse_document'),
]


@pytest.mark.parametrize('q,tool', QUERIES)
def test_the_right_tool_is_offered(T, q, tool):
    assert tool in agent.select_tools(T, q), (q, agent.select_tools(T, q))


def test_code_tools_exist_only_with_allow_code(tmp_path):
    assert 'python_run' in agent.Tools(str(tmp_path), knowledge.load(None), allow_code=True).t
    assert 'python_run' not in agent.Tools(str(tmp_path), knowledge.load(None), allow_code=False).t


def test_python_run_runs_code_lists_files_and_reports_errors(T):
    r = T.call('python_run', {'code': "import numpy as np\nw=[8,10,12]\nfor t in w: print(t, round(7850*2*1*t/1000,1))\nopen('weights.txt','w').write('ok')\n"})
    assert r['exit_code'] == 0 and '8 125.6' in r['output'] and 'weights.txt' in r['files']
    bad = T.call('python_run', {'code': '1/0'})
    assert bad['exit_code'] != 0 and 'ZeroDivisionError' in bad['error_text']
    slow = T.call('python_run', {'code': 'import time; time.sleep(5)', 'timeout_s': 1})
    assert slow['exit_code'] == -1 and 'longer than 1 s' in slow['error_text']
