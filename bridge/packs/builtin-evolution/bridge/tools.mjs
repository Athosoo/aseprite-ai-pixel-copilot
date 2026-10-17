// 自扩展闭环的模型入口（arch §5.5）：这 6 个工具是"模型能修改自己"的手柄。
// 它们只做参数校验与转发 —— 护栏全在 evolution.mjs 里，绕不过去。
export default {
  tools: [
    {
      name: 'list_capabilities',
      description: 'Search what this build can actually do, by keyword (tool-search). Capabilities are deliberately NOT in your prompt, so call this before you tell the user something is impossible. query matches tool name, pack id and description.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'keyword, e.g. "sharpen", "layer", "colour", "pack"' },
          limit: { type: 'integer', description: 'max entries to return, default 40' },
        },
        required: [],
      },
      async run(ctx, input) {
        const q = String(input.query ?? '').trim().toLowerCase();
        const limit = Number.isInteger(input.limit) && input.limit > 0 ? Math.min(input.limit, 200) : 40;
        // 描述只取首句：整段塞回去等于把 schema 又搬进上下文，那就白省了
        const all = ctx.registry.list()
          .filter((s) => s.expose !== false)
          .map((s) => ({
            name: s.name,
            pack: s.pack,
            description: String(s.description || '').split(/(?<=[.。])\s/)[0],
            evolved: !!s.meta?.evolved,
          }));
        const matched = q
          ? all.filter((c) => (c.name + ' ' + c.pack + ' ' + c.description).toLowerCase().includes(q))
          : all;
        return { query: q, total: all.length, matched: matched.length, caps: matched.slice(0, limit) };
      },
    },
    {
      name: 'propose_pack',
      description: 'Stage a capability pack you wrote (manifest.json + tests.mjs + optional bridge/tools.mjs). Nothing goes live: files land in the staging area only, and the pack must pass verify_pack and activate_pack. Guards: at most 3 proposals per turn; one pack may be at most 200 lines / 32KB; only relative paths inside the staging dir are writable.',
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'pack id, lowercase kebab-case, e.g. "sharpen-pack"' },
          files: {
            type: 'object',
            description: 'relative path -> file content, e.g. {"manifest.json": "{...}", "tests.mjs": "export default [...]"}',
            additionalProperties: { type: 'string' },
          },
          rationale: { type: 'string', description: 'what user-visible problem this solves (one sentence)' },
        },
        required: ['id', 'files'],
      },
      async run(ctx, input) {
        return ctx.evolution.propose({ id: input.id, files: input.files, rationale: input.rationale });
      },
    },
    {
      name: 'verify_pack',
      description: 'Run a staged pack\'s own tests.mjs in a killable subprocess (hard timeout). Fails when tests.mjs is missing, makes zero assertions, or when manifest.ops[].name is not a real callable tool. Only a verified pack may be activated.',
      inputSchema: {
        type: 'object',
        properties: {
          staged: { type: 'string', description: 'the staging path returned by propose_pack' },
        },
        required: ['staged'],
      },
      async run(ctx, input) {
        return ctx.evolution.verify({ staged: input.staged });
      },
    },
    {
      name: 'activate_pack',
      description: 'Make a verified pack live: snapshots the previous version, copies the staged files into the packs dir, hot-loads them (no restart) and rolls back automatically if loading fails. Keeps the last 3 versions.',
      inputSchema: {
        type: 'object',
        properties: {
          staged: { type: 'string', description: 'the staging path returned by propose_pack (must have passed verify_pack)' },
        },
        required: ['staged'],
      },
      async run(ctx, input) {
        return ctx.evolution.activate({ staged: input.staged });
      },
    },
    {
      name: 'rollback_pack',
      description: 'Restore the previous version of an activated pack from its snapshot and hot-reload it.',
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'pack id to roll back' },
        },
        required: ['id'],
      },
      async run(ctx, input) {
        return ctx.evolution.rollback({ id: input.id });
      },
    },
    {
      name: 'pack_health',
      description: 'Per-pack runtime health (calls, fails, msAvg) plus the staging/verify state. A pack whose failure rate stays above the threshold is rolled back automatically.',
      inputSchema: { type: 'object', properties: {}, required: [] },
      async run(ctx) {
        const rolledBack = await ctx.evolution.healthCheck();
        return { packs: ctx.evolution.health(), stats: ctx.evolution.stats(), rolledBack };
      },
    },
  ],
};
