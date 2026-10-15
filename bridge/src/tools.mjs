// Tool registry: the capabilities exposed to the LLM.
//
// Key design: the model NEVER emits pixels, only structured ops which
// deterministic Lua code executes. Image-wide work goes through Perfect
// Pixel Studio's core algorithm instead of asking the model to guess.

import { perfectPixel } from './perfectpixel.mjs';

const REGION_SCHEMA = {
  type: 'object',
  description: 'Rectangular region in pixel coordinates (origin at top-left). Omit = whole canvas.',
  properties: {
    x: { type: 'integer' },
    y: { type: 'integer' },
    w: { type: 'integer' },
    h: { type: 'integer' },
  },
};

export const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'canvas_info',
      description: 'Re-read the current Aseprite canvas state (size, layers, selection, colour usage, snapshot count). Call it when unsure about the current state.',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'apply_ops',
      description:
        'Run a list of canvas ops on the active layer. The system snapshots first; the whole batch is one undo step. ' +
        'Ops: ' +
        'replace_color(from,to,tolerance) swaps one colour for another; ' +
        'erase_color(color) makes a colour transparent; ' +
        'erase_region(region) clears a rectangle; ' +
        'fill_region(region,color) fills a rectangle; ' +
        'outline(color) draws a 1px outline around opaque pixels; ' +
        'despeckle(maxCluster) deletes isolated blobs; ' +
        'palette_map(map) remaps colours and updates the palette.',
      parameters: {
        type: 'object',
        properties: {
          label: {
            type: 'string',
            description: 'Short description of this edit; becomes the undo step name, e.g. "background to blue"',
          },
          ops: {
            type: 'array',
            description: 'Ops to run in order',
            items: {
              type: 'object',
              properties: {
                op: {
                  type: 'string',
                  enum: [
                    'replace_color',
                    'erase_color',
                    'erase_region',
                    'fill_region',
                    'outline',
                    'despeckle',
                    'palette_map',
                  ],
                },
                from: { type: 'string', description: 'replace_color: source colour #RRGGBB' },
                to: { type: 'string', description: 'replace_color: target colour #RRGGBB (8 digits also sets alpha)' },
                color: { type: 'string', description: 'erase_color / fill_region / outline: colour #RRGGBB' },
                region: REGION_SCHEMA,
                tolerance: { type: 'integer', description: 'per-channel RGB tolerance, default 0 (exact match)' },
                maxCluster: { type: 'integer', description: 'despeckle: blob size to remove, default 1' },
                map: {
                  type: 'object',
                  description: 'palette_map: { "#old": "#new" } colour map',
                  additionalProperties: { type: 'string' },
                },
                updatePalette: {
                  type: 'boolean',
                  description: 'palette_map: also update palette entries, default true',
                },
              },
              required: ['op'],
            },
          },
        },
        required: ['label', 'ops'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'crop',
      description:
        'Crop the canvas down to a rectangular region. Pixels are kept EXACTLY as they are (no resampling). ' +
        'Use it to remove empty margins or cut out part of the image. ' +
        'Rule of thumb: if the user says "shrink to NxN" and canvas_info shows a lot of padding around the content, ' +
        'they usually mean crop, not scale. The region must lie inside the current canvas.',
      parameters: {
        type: 'object',
        properties: {
          x: { type: 'integer', description: 'left edge, 0-based' },
          y: { type: 'integer', description: 'top edge, 0-based' },
          w: { type: 'integer', description: 'width in pixels' },
          h: { type: 'integer', description: 'height in pixels' },
          label: { type: 'string', description: 'short description; becomes the undo step name' },
        },
        required: ['x', 'y', 'w', 'h'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'scale',
      description:
        'Resize the WHOLE image — canvas and artwork together — by resampling. ' +
        'Use it when the user wants the same picture at a different size (e.g. "make this 64x64 into 32x32"). ' +
        'Shrinking loses fine detail, so for pixel art keep method=nearest. ' +
        'If the goal is really to trim empty margins, use crop instead — that keeps pixels untouched.',
      parameters: {
        type: 'object',
        properties: {
          width: { type: 'integer' },
          height: { type: 'integer' },
          method: {
            type: 'string',
            enum: ['nearest', 'bilinear'],
            description: 'default nearest (keeps pixel art crisp); bilinear smooths, rarely what pixel artists want',
          },
          label: { type: 'string' },
        },
        required: ['width', 'height'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'canvas_size',
      description:
        'Change the canvas size WITHOUT scaling the artwork — content keeps its original pixel size and is placed by anchor. ' +
        'Use when the user wants more room around the art or less, e.g. "add a 4px border" or "make the canvas 32x32 but keep the sprite as is".',
      parameters: {
        type: 'object',
        properties: {
          width: { type: 'integer' },
          height: { type: 'integer' },
          anchor: {
            type: 'string',
            enum: ['center', 'top-left', 'top-right', 'bottom-left', 'bottom-right'],
            description: 'where the existing content sits inside the new canvas; default center',
          },
          label: { type: 'string' },
        },
        required: ['width', 'height'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'style_list',
      description: 'List the available art styles (palette + layer structure + drawing rules). Call this before guessing what style the user means.',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'style_use',
      description:
        'Switch to an art style. From then on its palette, layer structure and rules are part of your instructions, ' +
        'and you should follow them for anything you draw. Pass an empty name to clear the style. ' +
        'Call style_list first if you are not sure of the exact name.',
      parameters: {
        type: 'object',
        properties: { name: { type: 'string', description: 'style name; empty string clears it' } },
        required: ['name'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'style_save',
      description:
        'Save a reusable art style. Use when the user describes a style they want to keep, or after you have settled on a palette and rules together.',
      parameters: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'short id, letters/digits/hyphen/CJK' },
          label: { type: 'string', description: 'human-readable name' },
          size: { type: 'array', items: { type: 'integer' }, description: '[width, height] the style is drawn at' },
          palette: { type: 'array', items: { type: 'string' }, description: 'colours as #RRGGBB' },
          layers: { type: 'array', items: { type: 'string' }, description: 'layer names, bottom to top' },
          rules: { type: 'array', items: { type: 'string' }, description: 'short drawing rules, one per entry' },
          notes: { type: 'string' },
        },
        required: ['name'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'new_sprite',
      description:
        'Create a new empty document. Use it before drawing from scratch. ' +
        'If an art style is active, prefer the size that style recommends unless the user asked for something else.',
      parameters: {
        type: 'object',
        properties: {
          width: { type: 'integer' },
          height: { type: 'integer' },
          colorMode: { type: 'string', enum: ['rgb', 'indexed', 'grayscale'], description: 'default rgb' },
        },
        required: ['width', 'height'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'add_layer',
      description:
        'Add a layer to the current document (placed above the active one). ' +
        'When a style defines a layer structure, create those layers so later edits can target them by name. ' +
        'draw_art also creates the layer if it does not exist, so this is only needed when you want an empty layer up front.',
      parameters: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          opacity: { type: 'integer', description: '0-255, default 255' },
          blendMode: { type: 'string', enum: ['normal', 'multiply', 'screen', 'overlay', 'addition'] },
        },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'draw_art',
      description:
        'Draw pixels from a character grid — this is how you draw, do NOT emit pixel coordinate lists. ' +
        'Each character in rows is one pixel, mapped through palette. Example: ' +
        'palette {".": "", "X": "#2E86DE", "o": "#7EE2A8"}, rows ["..XX..", ".XooX.", "XooooX"] ' +
        '(a "." or empty colour means transparent). Every row must be the same length. ' +
        'The whole grid becomes one undo step. The layer is created if it does not exist. ' +
        'Keep grids modest: up to about 32x32 is reliable. For bigger pieces, draw in passes — ' +
        'one draw_art per layer (base colours, then shading, then highlights).',
      parameters: {
        type: 'object',
        properties: {
          rows: {
            type: 'array',
            items: { type: 'string' },
            description: 'one string per pixel row, all the same length',
          },
          palette: {
            type: 'object',
            description: '{ character: "#RRGGBB" }; map a character to "" for transparent',
            additionalProperties: { type: 'string' },
          },
          layer: { type: 'string', description: 'target layer name; created if missing' },
          x: { type: 'integer', description: 'left offset in the canvas, default 0' },
          y: { type: 'integer', description: 'top offset in the canvas, default 0' },
          label: { type: 'string', description: 'short description for the undo step' },
        },
        required: ['rows', 'palette'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'perfect_pixel',
      description:
        'Run Perfect Pixel Studio\'s core algorithm: detect the pixel grid of an image that only looks like pixel art (skewed cells, blurry edges) and resample it into true pixel art. ' +
        'The result opens as a NEW document in Aseprite so the user can copy from it. ' +
        'Use source="uploaded" when the user uploaded an image, source="active_canvas" to fix the canvas they have open. ' +
        'If automatic detection fails, retry with an explicit gridSize such as [32,32].',
      parameters: {
        type: 'object',
        properties: {
          source: {
            type: 'string',
            enum: ['uploaded', 'active_canvas'],
            description: 'which image to fix, default uploaded',
          },
          gridSize: {
            type: 'array',
            description: 'explicit grid size [w,h], e.g. [32,32]; omit for automatic detection',
            items: { type: 'integer' },
          },
          sampleMethod: {
            type: 'string',
            enum: ['center', 'median', 'majority'],
            description: 'sampling method, default center (highest fidelity, byte-identical to the official Python port)',
          },
          fixSquare: { type: 'boolean', description: 'force square output when nearly square, default true' },
        },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'snapshot',
      description: 'Store a named snapshot (temp version) of the current canvas. Edits are already auto-backed-up; use this when the user explicitly asks to save a version.',
      parameters: {
        type: 'object',
        properties: { label: { type: 'string', description: 'snapshot name, e.g. "before outline"' } },
        required: ['label'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'rollback',
      description: 'Roll back to a snapshot version. Pass the version number, or "last" for the most recent snapshot.',
      parameters: {
        type: 'object',
        properties: {
          to: { type: 'string', description: 'version number (e.g. "3") or "last"' },
        },
        required: ['to'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_versions',
      description: 'List all snapshot versions of the current canvas (number, time, label, cel count).',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'remember',
      description:
        'Store something worth keeping long-term: a palette the user settled on, a style rule, a project convention, a preference. ' +
        'Call this when the user explicitly asks you to remember something, or when they state a durable preference. ' +
        'Do NOT use it for routine edits or transient state. Keep text short — one fact per call. ' +
        'What you store is NOT injected into every request; it is retrieved on demand with recall.',
      parameters: {
        type: 'object',
        properties: {
          kind: {
            type: 'string',
            enum: ['color', 'style', 'preference', 'project', 'note'],
            description: 'category; default note',
          },
          text: { type: 'string', description: 'the fact itself, short and self-contained' },
          tags: { type: 'array', items: { type: 'string' }, description: 'keywords for later retrieval' },
          note: { type: 'string', description: 'optional extra context' },
        },
        required: ['text'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'recall',
      description:
        'Search what has been remembered before. Call this BEFORE guessing what the user preferred earlier, ' +
        'or when they refer to something established previously. Returns only the few best matches.',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'keyword to match against text / tags / note' },
          kind: { type: 'string', enum: ['color', 'style', 'preference', 'project', 'note'], description: 'restrict to one category' },
          tags: { type: 'array', items: { type: 'string' }, description: 'require these tags' },
          limit: { type: 'integer', description: 'max entries to return, default 6' },
        },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'forget',
      description: 'Delete one stored memory by its id (ids come from recall). Use when the user says something is no longer true.',
      parameters: {
        type: 'object',
        properties: { id: { type: 'string' } },
        required: ['id'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'remember_color',
      description: 'Remember a colour and the context it is used in, so it can be found later with search_colors.',
      parameters: {
        type: 'object',
        properties: {
          hex: { type: 'string', description: '#RRGGBB' },
          scene: { type: 'string', description: 'where it is used, e.g. "blue shell body" or "skin highlight"' },
          tags: { type: 'array', items: { type: 'string' }, description: 'tags for retrieval' },
          note: { type: 'string', description: 'free-form note' },
        },
        required: ['hex', 'scene'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'search_colors',
      description: 'Search previously remembered colours and their contexts. Query by keyword, colour, or tag.',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'keyword (matches scene / note / tags / hex)' },
          hex: { type: 'string', description: 'look up a specific colour' },
          tag: { type: 'string', description: 'look up by tag' },
          limit: { type: 'integer', description: 'max entries to return, default 12' },
        },
        required: [],
      },
    },
  },
];

export function makeDispatcher({ session, bank, memory, styles, cfg, bundlePath, getActiveStyle, setActiveStyle }) {
  return async function dispatch(name, args) {
    switch (name) {
      case 'canvas_info':
        return await session.request('canvas_info');

      case 'crop':
        return await session.request('crop', {
          label: args.label || `crop to ${args.w}x${args.h}`,
          x: args.x, y: args.y, w: args.w, h: args.h,
        });

      case 'scale':
        return await session.request('scale', {
          label: args.label || `scale to ${args.width}x${args.height}`,
          width: args.width, height: args.height, method: args.method,
        });

      case 'canvas_size':
        return await session.request('canvas_size', {
          label: args.label || `canvas ${args.width}x${args.height}`,
          width: args.width, height: args.height, anchor: args.anchor,
        });

      case 'apply_ops': {
        if (!Array.isArray(args.ops) || args.ops.length === 0) {
          return { error: 'ops is empty' };
        }
        return await session.request('run_ops', {
          label: args.label || 'AI edit',
          ops: args.ops,
        });
      }

      case 'perfect_pixel': {
        const source = args.source || 'uploaded';
        let buf, w, h, note;
        if (source === 'uploaded') {
          if (!session.upload) {
            return { error: 'No image has been uploaded yet. Pick a file in the panel and click "Fix Image".' };
          }
          ({ buf, w, h } = session.upload);
          note = `from upload ${session.upload.name}`;
        } else {
          const got = await session.request('get_canvas');
          if (got.error) return got;
          buf = got.buf;
          w = got.width;
          h = got.height;
          note = 'from the active canvas';
        }

        const res = await perfectPixel(bundlePath, buf, w, h, {
          sampleMethod: args.sampleMethod,
          gridSize: args.gridSize,
          fixSquare: args.fixSquare,
        });

        if (!res.detected) {
          return {
            detected: false,
            inputWidth: res.inputWidth,
            inputHeight: res.inputHeight,
            reason: res.message,
            hint: 'Detection failed. Ask the user for the logical grid size and retry with gridSize, e.g. [32,32].',
          };
        }

        await session.sendImport(res.data, res.outWidth, res.outHeight, note);

        return {
          detected: true,
          input: `${res.inputWidth}x${res.inputHeight}`,
          grid: `${res.gridW}x${res.gridH}`,
          refined: `${res.refinedW}x${res.refinedH}`,
          output: `${res.outWidth}x${res.outHeight}`,
          note: 'Result opened as a new document; the user can copy from it.',
        };
      }

      case 'snapshot':
        return await session.request('snapshot', { label: args.label || 'AI snapshot' });

      case 'rollback':
        return await session.request('rollback', { to: String(args.to ?? 'last') });

      case 'list_versions':
        return await session.request('list_versions');

      case 'remember':
        return memory.remember(args);

      // ---- 风格 ----------------------------------------------------------
      case 'style_list': {
        const cur = getActiveStyle ? getActiveStyle() : '';
        return {
          active: cur || null,
          styles: styles.names().map((n) => {
            const s = styles.get(n);
            return {
              name: n,
              label: s.label || n,
              size: s.size ? `${s.size[0]}x${s.size[1]}` : null,
              colors: s.palette?.length || 0,
              layers: s.layers || [],
            };
          }),
        };
      }

      case 'style_use': {
        const want = String(args.name ?? '').trim();
        if (want === '') {
          setActiveStyle('');
          return { ok: true, active: null, note: 'style cleared' };
        }
        const s = styles.get(want);
        if (!s) {
          return { error: `no style named "${want}"`, available: styles.names() };
        }
        setActiveStyle(s.name);
        return {
          ok: true,
          active: s.name,
          label: s.label || s.name,
          note: 'This style is now part of your instructions for the rest of the session.',
        };
      }

      case 'style_save':
        return styles.save(args.name, args);

      // ---- 作画 ----------------------------------------------------------
      case 'new_sprite':
        return await session.request('new_sprite', {
          width: args.width, height: args.height, colorMode: args.colorMode,
        });

      case 'add_layer':
        return await session.request('add_layer', {
          name: args.name, opacity: args.opacity, blendMode: args.blendMode,
        });

      case 'draw_art': {
        if (!Array.isArray(args.rows) || args.rows.length === 0) {
          return { error: 'rows is empty: pass an array of strings, one per pixel row' };
        }
        // 先把"行宽不一致"挡在桥这一侧：模型写歪一行，报错要比让 Lua 抛更早、更好懂
        const w = String(args.rows[0]).length;
        const badRow = args.rows.findIndex((r) => String(r).length !== w);
        if (badRow >= 0) {
          return {
            error: `row ${badRow + 1} has ${String(args.rows[badRow]).length} characters but row 1 has ${w}; every row must be the same length`,
          };
        }
        const chars = new Set(args.rows.join('').split(''));
        const pal = args.palette || {};
        const unmapped = [...chars].filter((c) => !(c in pal) && c !== ' ' && c !== '.');
        if (unmapped.length) {
          return {
            error: `these characters appear in rows but have no palette entry: ${unmapped.join(' ')}`,
            hint: 'add them to palette, or use "." for transparent',
          };
        }
        return await session.request('draw_art', {
          label: args.label || `draw ${w}x${args.rows.length}`,
          layer: args.layer, palette: pal, rows: args.rows, x: args.x, y: args.y,
        });
      }

      case 'recall':
        return memory.recall(args);

      case 'forget':
        return memory.forget(args);

      case 'remember_color':
        return bank.remember(args);

      case 'search_colors':
        return bank.search(args);

      default:
        return { error: `unknown tool: ${name}` };
    }
  };
}
