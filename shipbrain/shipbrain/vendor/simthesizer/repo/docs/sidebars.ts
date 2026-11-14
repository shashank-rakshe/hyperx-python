import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Getting started',
      collapsed: false,
      items: ['getting-started/installation', 'getting-started/quickstart'],
    },
    {
      type: 'category',
      label: 'Framework',
      collapsed: false,
      items: ['framework/agent-workflow', 'framework/extending'],
    },
    {
      type: 'category',
      label: 'Simulator',
      collapsed: false,
      items: [
        'simulator/overview',
        'simulator/event-engine',
        'simulator/serving-systems',
        'simulator/scheduling',
        'simulator/model-execution',
        'simulator/cost-models',
      ],
    },
    {
      type: 'category',
      label: 'Reference',
      collapsed: false,
      items: [
        'reference/configuration',
        'reference/workload-format',
        'reference/profiling',
        'reference/validation',
      ],
    },
  ],
};

export default sidebars;
