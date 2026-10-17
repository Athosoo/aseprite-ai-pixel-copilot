// 记忆与色库 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "remember",
      description: "Store something worth keeping long-term: a palette the user settled on, a style rule, a project convention, a preference. Call this when the user explicitly asks you to remember something, or when they state a durable preference. Do NOT use it for routine edits or transient state. Keep text short — one fact per call. What you store is NOT injected into every request; it is retrieved on demand with recall.",
      inputSchema: {
        type: "object",
        properties: {
          kind: {
            type: "string",
            enum: ["color","style","preference","project","note"],
            description: "category; default note"
          },
          text: {
            type: "string",
            description: "the fact itself, short and self-contained"
          },
          tags: {
            type: "array",
            items: {
              type: "string"
            },
            description: "keywords for later retrieval"
          },
          note: {
            type: "string",
            description: "optional extra context"
          }
        },
        required: ["text"]
      },
      async run(ctx, input) {

        return ctx.memory.remember(input);
      },
    },
    {
      name: "recall",
      description: "Search what has been remembered before. Call this BEFORE guessing what the user preferred earlier, or when they refer to something established previously. Returns only the few best matches.",
      inputSchema: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "keyword to match against text / tags / note"
          },
          kind: {
            type: "string",
            enum: ["color","style","preference","project","note"],
            description: "restrict to one category"
          },
          tags: {
            type: "array",
            items: {
              type: "string"
            },
            description: "require these tags"
          },
          limit: {
            type: "integer",
            description: "max entries to return, default 6"
          }
        },
        required: []
      },
      async run(ctx, input) {

        return ctx.memory.recall(input);
      },
    },
    {
      name: "forget",
      description: "Delete one stored memory by its id (ids come from recall). Use when the user says something is no longer true.",
      inputSchema: {
        type: "object",
        properties: {
          id: {
            type: "string"
          }
        },
        required: ["id"]
      },
      async run(ctx, input) {

        return ctx.memory.forget(input);
      },
    },
    {
      name: "remember_color",
      description: "Remember a colour and the context it is used in, so it can be found later with search_colors.",
      inputSchema: {
        type: "object",
        properties: {
          hex: {
            type: "string",
            description: "#RRGGBB"
          },
          scene: {
            type: "string",
            description: "where it is used, e.g. \"blue shell body\" or \"skin highlight\""
          },
          tags: {
            type: "array",
            items: {
              type: "string"
            },
            description: "tags for retrieval"
          },
          note: {
            type: "string",
            description: "free-form note"
          }
        },
        required: ["hex","scene"]
      },
      async run(ctx, input) {

        return ctx.bank.remember(input);
      },
    },
    {
      name: "search_colors",
      description: "Search previously remembered colours and their contexts. Query by keyword, colour, or tag.",
      inputSchema: {
        type: "object",
        properties: {
          query: {
            type: "string",
            description: "keyword (matches scene / note / tags / hex)"
          },
          hex: {
            type: "string",
            description: "look up a specific colour"
          },
          tag: {
            type: "string",
            description: "look up by tag"
          },
          limit: {
            type: "integer",
            description: "max entries to return, default 12"
          }
        },
        required: []
      },
      async run(ctx, input) {

        return ctx.bank.search(input);
      },
    },
  ],
};
