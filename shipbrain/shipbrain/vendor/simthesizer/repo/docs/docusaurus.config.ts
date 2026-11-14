import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const repo = 'https://github.com/casys-kaist/Simthesizer';
const paper = 'https://arxiv.org/abs/2608.24650';

const config: Config = {
  title: 'Simthesizer',
  tagline: 'An agent-driven simulation framework for LLM serving systems',
  favicon: 'img/logo.svg',

  future: {
    v4: true,
  },

  url: 'https://simthesizer.ai',
  baseUrl: '/',

  organizationName: 'casys-kaist',
  projectName: 'Simthesizer',
  trailingSlash: false,

  headTags: [
    {
      tagName: 'link',
      attributes: {rel: 'preconnect', href: 'https://fonts.googleapis.com'},
    },
    {
      tagName: 'link',
      attributes: {
        rel: 'preconnect',
        href: 'https://fonts.gstatic.com',
        crossorigin: 'anonymous',
      },
    },
  ],

  stylesheets: [
    'https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500..800&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500;700&display=swap',
  ],

  onBrokenLinks: 'throw',

  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'throw',
    },
  },

  themes: [
    '@docusaurus/theme-mermaid',
    [
      '@easyops-cn/docusaurus-search-local',
      {
        // A static index built at build time and shipped to the client.
        hashed: true,
        indexBlog: false,
        indexPages: true,
        docsRouteBasePath: '/docs',
        highlightSearchTermsOnTargetPage: true,
        explicitSearchResultPath: true,
      },
    ],
  ],

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: `${repo}/tree/main/docs/`,
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: false,
    },
    // One palette for both modes: dark panels with teal borders and amber
    // edges read on the white background and the instrument background.
    mermaid: {
      theme: {light: 'base', dark: 'base'},
      options: {
        themeVariables: {
          darkMode: true,
          background: '#12151c',
          primaryColor: '#1d222d',
          primaryTextColor: '#e6e8ee',
          primaryBorderColor: '#2dd4bf',
          secondaryColor: '#1d222d',
          tertiaryColor: '#12151c',
          lineColor: '#ffb224',
          edgeLabelBackground: '#12151c',
          clusterBkg: '#12151c',
          clusterBorder: '#2a2f3a',
          fontFamily: 'Inter, sans-serif',
          fontSize: '15px',
        },
      },
    },
    navbar: {
      logo: {
        alt: 'Simthesizer',
        src: 'img/wordmark-light.svg',
        srcDark: 'img/wordmark-dark.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docs',
          position: 'left',
          label: 'For Users',
        },
        {to: '/contact', label: 'Contact', position: 'right'},
        {href: paper, label: 'Paper', position: 'right'},
        {href: repo, label: 'GitHub', position: 'right'},
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {label: 'Getting started', to: '/docs/getting-started/installation'},
            {label: 'Agent workflow', to: '/docs/framework/agent-workflow'},
            {label: 'Simulator', to: '/docs/simulator/overview'},
            {label: 'Workload format', to: '/docs/reference/workload-format'},
          ],
        },
        {
          title: 'Project',
          items: [
            {label: 'GitHub', href: repo},
            {label: 'Issues', href: `${repo}/issues`},
            {label: 'Paper (arXiv)', href: paper},
            {label: 'Contact', to: '/contact'},
          ],
        },
        {
          title: 'Group',
          items: [{label: 'CASYS @ KAIST', href: 'https://casys.kaist.ac.kr/'}],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} CASYS @ KAIST. Released under the MIT License.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.vsDark,
      additionalLanguages: ['bash', 'toml', 'json', 'rust'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
