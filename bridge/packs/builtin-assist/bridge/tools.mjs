// 对话与自省 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "ask_user",
      description: "Ask the user to pick one of a few options. The panel turns this into clickable buttons, so it is much better than asking in prose when you genuinely need the user to decide something (overwrite the original or keep the copy, which of two looks, which file, which size). Do NOT use it for small talk or for things you can figure out yourself. Returns the chosen option text, or { cancelled: true } if the user dismissed it.",
      inputSchema: {
        type: "object",
        properties: {
          question: {
            type: "string",
            description: "One short question, in the user's language"
          },
          options: {
            type: "array",
            items: {
              type: "string"
            },
            description: "2 to 4 options, each under 30 characters, in the user's language"
          }
        },
        required: ["question","options"]
      },
      async run(ctx, input) {

        const question = String(input.question ?? '').trim();
        if (!question) return { error: 'ask_user needs a question' };
        const options = (Array.isArray(input.options) ? input.options : [])
          .map((s) => String(s).trim()).filter((s) => s !== '').slice(0, 4);
        if (options.length < 2) {
          return { error: 'ask_user needs 2 to 4 non-empty options' };
        }
        // 5 分钟：用户可能正在看图，别急着超时（request 的第三参就是超时）
        return await ctx.session.request('ask', { question, options }, 300000);
      },
    },
    {
      name: "log_gap",
      description: "Record a request you could NOT fulfil, into the project backlog file the developer reads. Call this EVERY time the user asks for something your tools cannot do (after you have checked capabilities), or when you had to refuse/limit a request. Say what they asked for and why it is not possible right now. Then still answer the user honestly -- logging is not a substitute for it.",
      inputSchema: {
        type: "object",
        properties: {
          request: {
            type: "string",
            description: "what the user asked for, in their words (short)"
          },
          why: {
            type: "string",
            description: "why it cannot be done with the current tools"
          },
          workaround: {
            type: "string",
            description: "what you offered instead, if anything"
          }
        },
        required: ["request","why"]
      },
      async run(ctx, input) {

        if (!ctx.gaps) return { error: 'gap log is not available' };
        return ctx.gaps.add({
          request: input.request,
          why: input.why,
          workaround: input.workaround,
          tool: ctx.session?.lastTool || '',
          model: ctx.cfg?.llm?.model || '',
          context: ctx.session?.lastUserText || '',
          source: 'model',
        });
      },
    },
    {
      name: "capabilities",
      description: "Read your own capability list: which tools you actually have, and what you explicitly cannot do. Call it before answering \"can you do X?\" style questions, and whenever the user asks what you are able to do. Never promise anything that is not in this list.",
      inputSchema: {
        type: "object",
        properties: {},
        required: []
      },
      async run(ctx, input) {

        return ctx.buildCapabilities();
      },
    },
  ],
};
