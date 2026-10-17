// 工作区与文档 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "open_document",
      description: "Open an image or Aseprite document in Aseprite, by path. Relative paths resolve against the workspace root, then against the folder of the current document. Use it when the user says \"open X\" or wants to work on another file. Returns the document name and size.",
      inputSchema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "absolute path, or a path relative to the workspace root"
          }
        },
        required: ["path"]
      },
      async run(ctx, input) {

        const path = String(input.path ?? '').trim();
        if (!path) return { error: 'path is required' };
        return await ctx.session.request('open_doc', { path }, 30000);
      },
    },
    {
      name: "list_workspace",
      description: "List the files the assistant has put in the workspace (uploads/ and backups/). Use it to answer \"where is the file you made?\" or to find the right name for open_document. Returns { root, files: [{name, path, dir}] }.",
      inputSchema: {
        type: "object",
        properties: {},
        required: []
      },
      async run(ctx, input) {

        return await ctx.session.request('list_workspace', {}, 20000);
      },
    },
  ],
};
