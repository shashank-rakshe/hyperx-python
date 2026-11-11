import type {ReactNode} from 'react';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import Layout from '@theme/Layout';
import ThemedImage from '@theme/ThemedImage';
import CodeBlock from '@theme/CodeBlock';
import {
  Activity,
  Boxes,
  Cable,
  ChartLine,
  ClipboardList,
  CodeXml,
  Cpu,
  FileCog,
  GitBranch,
  Layers,
  ListOrdered,
  Route,
  Server,
  ShieldCheck,
  Split,
  Timer,
  Workflow,
  type LucideIcon,
} from 'lucide-react';

import styles from './index.module.css';

const REPO = 'https://github.com/casys-kaist/Simthesizer';
const PAPER = 'https://arxiv.org/abs/2608.24650';

function Hero(): ReactNode {
  return (
    <header className={styles.hero}>
      <div className={styles.heroInner}>
        <h1 className={styles.heroTitle}>
          <ThemedImage
            className={styles.wordmark}
            alt="Simthesizer"
            sources={{
              light: useBaseUrl('/img/wordmark-light.svg'),
              dark: useBaseUrl('/img/wordmark-dark.svg'),
            }}
          />
        </h1>
        <p className={styles.tagline}>
          Agent-driven synthesis of accurate simulators for fast-evolving LLM serving systems
        </p>
        <div className={styles.buttons}>
          <Link className="button button--primary button--lg" to="/docs/getting-started/quickstart">
            Get started
          </Link>
          <Link className="button button--secondary button--lg" href={PAPER}>
            Paper
          </Link>
          <Link className="button button--secondary button--lg" href={REPO}>
            GitHub
          </Link>
        </div>
      </div>
    </header>
  );
}

function Name(): ReactNode {
  return (
    <section className={styles.nameBand}>
      <div className="container">
        <p className={styles.equation}>
          <span className={styles.term}>
            <b>sim</b>ulator
          </span>
          <span className={styles.op}>+</span>
          <span className={styles.term}>
            syn<b>thesizer</b>
          </span>
          <span className={styles.op}>=</span>
          <span className={styles.result}>Simthesizer</span>
        </p>
        <p className={styles.nameNote}>
          Describe a serving mechanism. A coding agent splices it into one shared simulator and
          validates its fidelity.
        </p>
      </div>
    </section>
  );
}

const IDEAS = [
  {
    kicker: 'Problem',
    title: 'LLM serving evolves fast',
    body: 'Every new serving mechanism means rewriting or forking a hand-built simulator.',
  },
  {
    kicker: 'Representation',
    title: 'One dynamic graph',
    body: 'All serving work is one event graph. New behavior enters as nodes; the engine never changes.',
  },
  {
    kicker: 'Process',
    title: 'An agent with guardrails',
    body: 'A coding agent implements each request and validates its fidelity.',
  },
];

function Ideas(): ReactNode {
  return (
    <section className={styles.section}>
      <div className="container">
        <div className={styles.cards3}>
          {IDEAS.map((idea) => (
            <article key={idea.title} className={styles.card}>
              <span className={styles.kicker}>{idea.kicker}</span>
              <h3>{idea.title}</h3>
              <p>{idea.body}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

const STAGES = [
  {skill: 'task-design', title: 'Specify behavior', Icon: ClipboardList},
  {skill: 'sim-mapping', title: 'Map to simulator', Icon: Route},
  {skill: 'sim-dev', title: 'Implement feature', Icon: CodeXml},
  {skill: 'sim-validation', title: 'Validate fidelity', Icon: ShieldCheck},
];

function Pipeline(): ReactNode {
  return (
    <section className={styles.section}>
      <div className="container">
        <SectionHead eyebrow="The framework" title="From a feature request to a validated simulator" />
        <ol className={styles.pipeline}>
          {STAGES.map(({skill, title, Icon}, i) => (
            <li key={skill} className={styles.stage}>
              <div className={styles.stageTop}>
                <span className={styles.stageIcon}>
                  <Icon size={30} strokeWidth={1.8} aria-hidden />
                </span>
                <span className={styles.stageIndex}>0{i + 1}</span>
              </div>
              <h3>{title}</h3>
              <code className={styles.stageSkill}>{skill}</code>
            </li>
          ))}
        </ol>
        <p className={styles.loopNote}>
          <span aria-hidden>↺</span> Corrections return to the stage that owns the error.{' '}
          <Link to="/docs/framework/agent-workflow">How the workflow works →</Link>
        </p>
      </div>
    </section>
  );
}

function Simulator(): ReactNode {
  return (
    <section className={`${styles.section} ${styles.sectionAlt}`}>
      <div className="container">
        <SectionHead eyebrow="The built-in simulator" title="A discrete-event simulator built from components" />
        <div className={styles.arch}>
          <div className={styles.archCol}>
            <span className={styles.archLabel}>Inputs</span>
            <Box kind="io" title="Scenario TOML" Icon={FileCog} />
            <Box kind="io" title="Workload JSONL" Icon={GitBranch} />
            <Box kind="io" title="Profile JSONL" Icon={Timer} />
          </div>
          <Arrow />
          <div className={styles.archCol}>
            <span className={styles.archLabel}>Component tree</span>
            <Box kind="system" title="System" Icon={Server} />
            <div className={styles.archRow}>
              <Box kind="comp" title="Scheduler" Icon={ListOrdered} />
              <Box kind="comp" title="Router" Icon={Split} />
            </div>
            <div className={styles.archRow}>
              <Box kind="comp" title="ModelRunner" Icon={Boxes} />
              <Box kind="comp" title="Model" Icon={Layers} />
            </div>
          </div>
          <Arrow label="nodes" />
          <div className={styles.archCol}>
            <span className={styles.archLabel}>Engine &amp; cost models</span>
            <Box kind="engine" title="Event graph" Icon={Workflow} />
            <Box kind="cost" title="ComputeSimulator" Icon={Cpu} />
            <Box kind="cost" title="NetworkSimulator" Icon={Cable} />
          </div>
          <Arrow />
          <div className={styles.archCol}>
            <span className={styles.archLabel}>Output</span>
            <Box kind="io" title="Result JSONL" Icon={ChartLine} />
            <Box kind="io" title="Engine trace" Icon={Activity} />
          </div>
        </div>
        <p className={styles.loopNote}>
          <Link to="/docs/simulator/overview">Explore the simulator architecture →</Link>
        </p>
      </div>
    </section>
  );
}

function Box({kind, title, Icon}: {kind: string; title: string; Icon: LucideIcon}): ReactNode {
  return (
    <div className={`${styles.box} ${styles[`box_${kind}`]}`}>
      <Icon className={styles.boxIcon} size={20} strokeWidth={1.8} aria-hidden />
      <strong>{title}</strong>
    </div>
  );
}

function Arrow({label}: {label?: string}): ReactNode {
  return (
    <div className={styles.arrow} aria-hidden>
      <span>{label}</span>
    </div>
  );
}

const BIBTEX = `@misc{simthesizer,
  title         = {Simthesizer: An Agent-Driven Simulation Framework for LLM Serving Systems},
  author        = {Kim, Wonung and Choi, Hyunmin and Kim, Minsu and Cho, Jaehong and Kim, Yeongwook and Park, Jongse},
  year          = {2026},
  eprint        = {2608.24650},
  archivePrefix = {arXiv}
}`;

function Citation(): ReactNode {
  return (
    <section className={styles.section}>
      <div className={`container ${styles.citeGrid}`}>
        <div>
          <SectionHead eyebrow="News" title="Updates" />
          <ul className={styles.news}>
            <li>
              <time>2026/11</time> Simthesizer is accepted to{' '}
              <Link href="https://hpca-conf.org/2027/">HPCA 2027</Link>.
            </li>
          </ul>
        </div>
        <div>
          <SectionHead eyebrow="Cite" title="Citation" />
          <CodeBlock language="text">{BIBTEX}</CodeBlock>
        </div>
      </div>
    </section>
  );
}

function SectionHead({eyebrow, title, lead}: {eyebrow: string; title: string; lead?: string}): ReactNode {
  return (
    <div className={styles.sectionHead}>
      <span className={styles.eyebrow}>{eyebrow}</span>
      <h2>{title}</h2>
      {lead && <p>{lead}</p>}
    </div>
  );
}

export default function Home(): ReactNode {
  return (
    <Layout
      title="Agent-driven simulation for LLM serving"
      description="An agent-driven simulation framework for LLM serving systems.">
      <Hero />
      <main>
        <Name />
        <Ideas />
        <Pipeline />
        <Simulator />
        <Citation />
      </main>
    </Layout>
  );
}
