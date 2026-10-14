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

export function makeDispatcher({ session, bank, cfg, bundlePath }) {
  return async function dispatch(name, args) {
    switch (name) {
      case 'canvas_info':
        return await session.request('canvas_info');

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

      case 'remember_color':
        return bank.remember(args);

      case 'search_colors':
        return bank.search(args);

      default:
        return { error: `unknown tool: ${name}` };
    }
  };
}
