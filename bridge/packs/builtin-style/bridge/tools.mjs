// 风格库 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "style_list",
      description: "List the available art styles (palette + layer structure + drawing rules). Call this before guessing what style the user means.",
      inputSchema: {
        type: "object",
        properties: {},
        required: []
      },
      async run(ctx, input) {

        const cur = ctx.getActiveStyle ? ctx.getActiveStyle() : '';
        return {
          active: cur || null,
          styles: ctx.styles.names().map((n) => {
            const s = ctx.styles.get(n);
            return {
              name: n,
              label: s.label || n,
              size: s.size ? s.size[0] + 'x' + s.size[1] : null,
              colors: s.palette?.length || 0,
              layers: s.layers || [],
            };
          }),
        };
      },
    },
    {
      name: "style_use",
      description: "Switch to an art style. From then on its palette, layer structure and rules are part of your instructions, and you should follow them for anything you draw. Pass an empty name to clear the style. Call style_list first if you are not sure of the exact name.",
      inputSchema: {
        type: "object",
        properties: {
          name: {
            type: "string",
            description: "style name; empty string clears it"
          }
        },
        required: ["name"]
      },
      async run(ctx, input) {

        const want = String(input.name ?? '').trim();
        if (want === '') {
          ctx.setActiveStyle('');
          return { ok: true, active: null, note: 'style cleared' };
        }
        const s = ctx.styles.get(want);
        if (!s) {
          return { error: 'no style named "' + want + '"', available: ctx.styles.names() };
        }
        ctx.setActiveStyle(s.name);
        return {
          ok: true,
          active: s.name,
          label: s.label || s.name,
          note: 'This style is now part of your instructions for the rest of the session.',
        };
      },
    },
    {
      name: "style_save",
      description: "Save a reusable art style. Use when the user describes a style they want to keep, or after you have settled on a palette and rules together.",
      inputSchema: {
        type: "object",
        properties: {
          name: {
            type: "string",
            description: "short id, letters/digits/hyphen/CJK"
          },
          label: {
            type: "string",
            description: "human-readable name"
          },
          size: {
            type: "array",
            items: {
              type: "integer"
            },
            description: "[width, height] the style is drawn at"
          },
          palette: {
            type: "array",
            items: {
              type: "string"
            },
            description: "colours as #RRGGBB"
          },
          layers: {
            type: "array",
            items: {
              type: "string"
            },
            description: "layer names, bottom to top"
          },
          rules: {
            type: "array",
            items: {
              type: "string"
            },
            description: "short drawing rules, one per entry"
          },
          notes: {
            type: "string"
          }
        },
        required: ["name"]
      },
      async run(ctx, input) {

        return ctx.styles.save(input.name, input);
      },
    },
  ],
};
