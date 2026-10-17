// 作画与图层 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "new_sprite",
      description: "Create a new empty document. Use it before drawing from scratch. If an art style is active, prefer the size that style recommends unless the user asked for something else.",
      inputSchema: {
        type: "object",
        properties: {
          width: {
            type: "integer"
          },
          height: {
            type: "integer"
          },
          colorMode: {
            type: "string",
            enum: ["rgb","indexed","grayscale"],
            description: "default rgb"
          }
        },
        required: ["width","height"]
      },
      async run(ctx, input) {

        return await ctx.session.request('new_sprite', {
          width: input.width, height: input.height, colorMode: input.colorMode,
        });
      },
    },
    {
      name: "add_layer",
      description: "Add a layer to the current document (placed above the active one). When a style defines a layer structure, create those layers so later edits can target them by name. draw_art also creates the layer if it does not exist, so this is only needed when you want an empty layer up front.",
      inputSchema: {
        type: "object",
        properties: {
          name: {
            type: "string"
          },
          opacity: {
            type: "integer",
            description: "0-255, default 255"
          },
          blendMode: {
            type: "string",
            enum: ["normal","multiply","screen","overlay","addition"]
          }
        },
        required: []
      },
      async run(ctx, input) {

        // 和 draw_art 同一条规矩：图层名必须 ASCII（见 isAsciiName 的注释）
        if (input.name != null && String(input.name).trim() !== '' && !ctx.isAsciiName(input.name)) {
          return {
            error: 'layer name must be ASCII: ' + input.name,
            hint: 'use english layer names like base / shadow / highlight / outline / detail',
          };
        }
        return await ctx.session.request('add_layer', {
          name: input.name, opacity: input.opacity, blendMode: input.blendMode,
        });
      },
    },
    {
      name: "draw_art",
      description: "Draw pixels from a character grid — this is how you draw, do NOT emit pixel coordinate lists. Each character in rows is one pixel, mapped through palette. Example: palette {\".\": \"\", \"X\": \"#2E86DE\", \"o\": \"#7EE2A8\"}, rows [\"..XX..\", \".XooX.\", \"XooooX\"] (a \".\" or empty colour means transparent). Every row must be the same length. The whole grid becomes one undo step. The layer is created if it does not exist. Keep grids modest: up to about 32x32 is reliable. For bigger pieces, draw in passes — one draw_art per layer (base colours, then shading, then highlights).",
      inputSchema: {
        type: "object",
        properties: {
          rows: {
            type: "array",
            items: {
              type: "string"
            },
            description: "one string per pixel row, all the same length"
          },
          palette: {
            type: "object",
            description: "{ character: \"#RRGGBB\" }; map a character to \"\" for transparent",
            additionalProperties: {
              type: "string"
            }
          },
          layer: {
            type: "string",
            description: "target layer name; created if missing"
          },
          x: {
            type: "integer",
            description: "left offset in the canvas, default 0"
          },
          y: {
            type: "integer",
            description: "top offset in the canvas, default 0"
          },
          label: {
            type: "string",
            description: "short description for the undo step"
          }
        },
        required: ["rows","palette"]
      },
      async run(ctx, input) {

        if (!Array.isArray(input.rows) || input.rows.length === 0) {
          return { error: 'rows is empty: pass an array of strings, one per pixel row' };
        }
        // "行宽不一致"挡在桥这一侧：模型写歪一行，报错要比让 Lua 抛更早、更好懂。
        // 宽度按【码点】算 —— JS 的 .length 是 UTF-16 单元数（emoji 算 2），
        // 而 Lua 侧用 utf8.codes 按码点数。两边不一致会让校验放过、Lua 再报错。
        if (input.layer != null && String(input.layer).trim() !== '' && !ctx.isAsciiName(input.layer)) {
          return {
            error: 'layer name must be ASCII: ' + input.layer,
            hint: 'use english layer names like base / shadow / highlight / outline / detail',
          };
        }
        const cps = (s2) => [...String(s2)].length;
        const w = cps(input.rows[0]);
        const badRow = input.rows.findIndex((r) => cps(r) !== w);
        if (badRow >= 0) {
          return {
            error: 'row ' + (badRow + 1) + ' has ' + cps(input.rows[badRow]) + ' characters but row 1 has ' + w + '; every row must be the same length',
          };
        }
        const chars = new Set(input.rows.join('').split(''));
        const pal = input.palette || {};
        const unmapped = [...chars].filter((c) => !(c in pal) && c !== ' ' && c !== '.');
        if (unmapped.length) {
          return {
            error: 'these characters appear in rows but have no palette entry: ' + unmapped.join(' '),
            hint: 'add them to palette, or use "." for transparent',
          };
        }
        // "." 和 " " 永远是透明的，给它们配颜色不会生效。与其让模型画出 0 像素
        // 再反复重试，不如在这里就说清楚（这个坑真的踩过：见 artlib 的 UTF-8 那段）。
        const dotPainted = ['.', ' '].filter((c) => typeof pal[c] === 'string' && pal[c].trim() !== '');
        if (dotPainted.length && [...chars].every((c) => c === '.' || c === ' ')) {
          return {
            error: 'every character in the grid is ' + dotPainted.map((c) => '"' + c + '"').join(' or ') + ', which are always transparent; palette entries for them are ignored',
            hint: 'use a real character (a letter or digit) for pixels that should be painted, and keep "." for the background',
          };
        }
        return await ctx.session.request('draw_art', {
          label: input.label || 'draw ' + w + 'x' + input.rows.length,
          layer: input.layer, palette: pal, rows: input.rows, x: input.x, y: input.y,
        });
      },
    },
  ],
};
