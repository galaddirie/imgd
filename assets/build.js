const path = require("path")
const esbuild = require("esbuild")
const sveltePlugin = require("esbuild-svelte")
const importGlobPlugin = require("esbuild-plugin-import-glob").default
const sveltePreprocess = require("svelte-preprocess")

const args = process.argv.slice(2)
const watch = args.includes("--watch")
const deploy = args.includes("--deploy")
const ssrEnabled = process.env.LIVE_SVELTE_SSR === "true"
const nodeEnv = deploy ? "production" : "development"
const mixEnv = process.env.MIX_ENV || "dev"
const projectRoot = path.resolve(__dirname, "..")
const extraNodePaths = [
  path.join(projectRoot, "deps"),
  path.join(projectRoot, "_build", mixEnv),
]
const nodeBuiltinsPlugin = {
  name: "node-builtins",
  setup(build) {
    build.onResolve({filter: /^node:/}, args => ({path: args.path, external: true}))
  },
}

let clientConditions = ["svelte", "browser"]
let serverConditions = ["svelte", "node"]

if (!deploy) {
  clientConditions.push("development")
  serverConditions.push("development")
}

let optsClient = {
  entryPoints: ["js/app.js"],
  bundle: true,
  minify: deploy,
  conditions: clientConditions,
  alias: {svelte: "svelte"},
  nodePaths: extraNodePaths,
  define: {"process.env.NODE_ENV": JSON.stringify(nodeEnv)},
  outdir: "../priv/static/assets/js",
  logLevel: "info",
  sourcemap: watch ? "inline" : false,
  tsconfig: "./tsconfig.json",
  plugins: [
    importGlobPlugin(),
    sveltePlugin({
      preprocess: sveltePreprocess({typescript: true}),
      compilerOptions: {dev: !deploy, css: "external", generate: "client"},
    }),
  ],
}

let optsServer = {
  entryPoints: ["js/server.js"],
  platform: "node",
  bundle: true,
  minify: false,
  target: "node19.6.1",
  conditions: serverConditions,
  alias: {svelte: "svelte"},
  nodePaths: extraNodePaths,
  define: {"process.env.NODE_ENV": JSON.stringify(nodeEnv)},
  outdir: "../priv/svelte",
  logLevel: "info",
  sourcemap: watch ? "inline" : false,
  tsconfig: "./tsconfig.json",
  plugins: [
    importGlobPlugin(),
    nodeBuiltinsPlugin,
    sveltePlugin({
      preprocess: sveltePreprocess({typescript: true}),
      compilerOptions: {dev: !deploy, css: "external", generate: "server"},
    }),
  ],
}

if (watch) {
  esbuild
    .context(optsClient)
    .then(ctx => ctx.watch())
    .catch(_error => process.exit(1))

  if (ssrEnabled) {
    esbuild
      .context(optsServer)
      .then(ctx => ctx.watch())
      .catch(_error => process.exit(1))
  }
} else {
  esbuild.build(optsClient)

  if (ssrEnabled) {
    esbuild.build(optsServer)
  }
}
