// 版本与快照 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "snapshot",
      description: "Store a named snapshot (temp version) of the current canvas. Edits are already auto-backed-up; use this when the user explicitly asks to save a version.",
      inputSchema: {
        type: "object",
        properties: {
          label: {
            type: "string",
            description: "snapshot name, e.g. \"before outline\""
          }
        },
        required: ["label"]
      },
      async run(ctx, input) {

        return await ctx.session.request('snapshot', { label: input.label || 'AI snapshot' });
      },
    },
    {
      name: "rollback",
      description: "Roll back to a snapshot version. Pass the version number, or \"last\" for the most recent snapshot.",
      inputSchema: {
        type: "object",
        properties: {
          to: {
            type: "string",
            description: "version number (e.g. \"3\") or \"last\""
          }
        },
        required: ["to"]
      },
      async run(ctx, input) {

        return await ctx.session.request('rollback', { to: String(input.to ?? 'last') });
      },
    },
    {
      name: "list_versions",
      description: "List all snapshot versions of the current canvas (number, time, label, cel count).",
      inputSchema: {
        type: "object",
        properties: {},
        required: []
      },
      async run(ctx, input) {

        return await ctx.session.request('list_versions');
      },
    },
  ],
};
