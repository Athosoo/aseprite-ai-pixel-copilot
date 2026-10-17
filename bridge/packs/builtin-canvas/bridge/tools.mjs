// 画布与尺寸 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "canvas_info",
      description: "Re-read the current Aseprite canvas state (size, layers, selection, colour usage, snapshot count). Call it when unsure about the current state.",
      inputSchema: {
        type: "object",
        properties: {},
        required: []
      },
      async run(ctx, input) {

        return await ctx.session.request('canvas_info');
      },
    },
    {
      name: "apply_ops",
      description: "Run a list of canvas ops. By default they apply to the ACTIVE LAYER only; pass layers:\"all\" to hit every layer of the current frame, or layers:[\"base\",\"detail\"] to pick specific ones. Image-wide requests (more contrast, sharpen, reduce the colours, swap a colour everywhere) almost always want layers:\"all\" on a multi-layer sprite -- an active-layer-only edit looks like \"nothing happened\" to the user, because the pixels they are looking at live on another layer. One transaction = one undo step for the whole batch, across all layers. The report gives changed pixels per op (and per layer when several were hit); if 0 pixels changed you also get a hint listing the layers that DO have content -- retarget with it instead of guessing. Ops: replace_color(from,to,tolerance) swaps one colour for another; erase_color(color) makes a colour transparent; erase_region(region) clears a rectangle; fill_region(region,color) fills a rectangle; outline(color) draws a 1px outline around opaque pixels; despeckle(maxCluster) deletes isolated blobs; palette_map(map) remaps colours and updates the palette; quantize(colors,updatePalette) reduces the image to at most N colours by median cut — use this whenever the user says the palette is too messy / too many colours / reduce to 32 or 64 colours / simplify, i.e. you do NOT need an explicit map for that; sharpen(amount,threshold) crisps up edges with a 3x3 unsharp mask (amount 1 = standard, 2+ = aggressive); contrast(amount,pivot) pushes every channel away from the mid tone, so darks get darker and lights lighter (amount 1.3 = +30%, 1 = unchanged). sharpen and contrast are the right answer for \"sharpen the edges / make it crisper / more contrast / darker shadows and brighter highlights / it looks flat\" — they are per-pixel, alpha is never touched.",
      inputSchema: {
        type: "object",
        properties: {
          label: {
            type: "string",
            description: "Short description of this edit; becomes the undo step name, e.g. \"background to blue\""
          },
          layer: {
            type: "string",
            description: "Optional: name of ONE layer to apply to (default: the active layer)"
          },
          layers: {
            type: "array",
            items: {
              type: "string"
            },
            description: "Optional: which layers to apply to. [\"all\"] = every layer of the current frame; otherwise a list of layer names (e.g. [\"base\",\"highlight\"]). Use \"all\" for any image-wide effect. Takes precedence over layer."
          },
          ops: {
            type: "array",
            description: "Ops to run in order",
            items: {
              type: "object",
              properties: {
                op: {
                  type: "string",
                  enum: [
                    "replace_color",
                    "erase_color",
                    "erase_region",
                    "fill_region",
                    "outline",
                    "despeckle",
                    "palette_map",
                    "quantize",
                    "sharpen",
                    "contrast",
                  ]
                },
                from: {
                  type: "string",
                  description: "replace_color: source colour #RRGGBB"
                },
                to: {
                  type: "string",
                  description: "replace_color: target colour #RRGGBB (8 digits also sets alpha)"
                },
                color: {
                  type: "string",
                  description: "erase_color / fill_region / outline: colour #RRGGBB"
                },
                region: {
                  type: "object",
                  description: "Rectangular region in pixel coordinates (origin at top-left). Omit = whole canvas.",
                  properties: {
                    x: {
                      type: "integer"
                    },
                    y: {
                      type: "integer"
                    },
                    w: {
                      type: "integer"
                    },
                    h: {
                      type: "integer"
                    }
                  }
                },
                tolerance: {
                  type: "integer",
                  description: "per-channel RGB tolerance, default 0 (exact match)"
                },
                maxCluster: {
                  type: "integer",
                  description: "despeckle: blob size to remove, default 1"
                },
                colors: {
                  type: "integer",
                  description: "quantize: target number of colours (2-256), e.g. 64 to merge a messy palette down to 64 colours"
                },
                map: {
                  type: "object",
                  description: "palette_map: { \"#old\": \"#new\" } colour map",
                  additionalProperties: {
                    type: "string"
                  }
                },
                updatePalette: {
                  type: "boolean",
                  description: "palette_map: also update palette entries, default true"
                },
                amount: {
                  type: "number",
                  description: "sharpen: edge strength, default 1 (2-3 is aggressive, use it only if the user asks for \"much sharper\"); contrast: contrast multiplier, default 1.3 (1 = unchanged, 0.5 = flatter, 2 = very strong)"
                },
                threshold: {
                  type: "integer",
                  description: "sharpen: leave pixels alone when their local difference is within this (0-255), default 0. Raise to 8-24 to keep flat areas and dither noise untouched."
                },
                pivot: {
                  type: "integer",
                  description: "contrast: the mid tone to expand around, default 128 (0-255). Lower it to keep highlights, raise it to keep shadows."
                }
              },
              required: ["op"]
            }
          }
        },
        required: ["label","ops"]
      },
      async run(ctx, input) {

        if (!Array.isArray(input.ops) || input.ops.length === 0) {
          return { error: 'ops is empty' };
        }
        // 目标层归一化：接受 layers:"all" / layers:["base"] / layer:"base" / 都不给（活动层）。
        // 单个名字压成字符串，Lua 侧就不用分两种形态解析。
        let targets;
        if (input.layers != null) targets = Array.isArray(input.layers) ? input.layers : [input.layers];
        else if (input.layer != null && String(input.layer).trim() !== '') targets = [String(input.layer)];
        if (Array.isArray(targets)) {
          targets = targets.map((t) => String(t).trim()).filter((t) => t !== '');
          if (targets.length === 0) targets = undefined;
          else if (targets.length === 1) targets = targets[0];
        }
        return await ctx.session.request('run_ops', {
          label: input.label || 'AI edit',
          ops: input.ops,
          layers: targets,
        });
      },
    },
    {
      name: "crop",
      description: "Crop the canvas down to a rectangular region. Pixels are kept EXACTLY as they are (no resampling). Use it to remove empty margins or cut out part of the image. Rule of thumb: if the user says \"shrink to NxN\" and canvas_info shows a lot of padding around the content, they usually mean crop, not scale. The region must lie inside the current canvas.",
      inputSchema: {
        type: "object",
        properties: {
          x: {
            type: "integer",
            description: "left edge, 0-based"
          },
          y: {
            type: "integer",
            description: "top edge, 0-based"
          },
          w: {
            type: "integer",
            description: "width in pixels"
          },
          h: {
            type: "integer",
            description: "height in pixels"
          },
          label: {
            type: "string",
            description: "short description; becomes the undo step name"
          }
        },
        required: ["x","y","w","h"]
      },
      async run(ctx, input) {

        return await ctx.session.request('crop', {
          label: input.label || 'crop to ' + input.w + 'x' + input.h,
          x: input.x, y: input.y, w: input.w, h: input.h,
        });
      },
    },
    {
      name: "scale",
      description: "Resize the WHOLE image — canvas and artwork together — by resampling. Use it when the user wants the same picture at a different size (e.g. \"make this 64x64 into 32x32\"). Shrinking loses fine detail, so for pixel art keep method=nearest. If the goal is really to trim empty margins, use crop instead — that keeps pixels untouched.",
      inputSchema: {
        type: "object",
        properties: {
          width: {
            type: "integer"
          },
          height: {
            type: "integer"
          },
          method: {
            type: "string",
            enum: ["nearest","bilinear"],
            description: "default nearest (keeps pixel art crisp); bilinear smooths, rarely what pixel artists want"
          },
          label: {
            type: "string"
          }
        },
        required: ["width","height"]
      },
      async run(ctx, input) {

        return await ctx.session.request('scale', {
          label: input.label || 'scale to ' + input.width + 'x' + input.height,
          width: input.width, height: input.height, method: input.method,
        });
      },
    },
    {
      name: "canvas_size",
      description: "Change the canvas size WITHOUT scaling the artwork — content keeps its original pixel size and is placed by anchor. Use when the user wants more room around the art or less, e.g. \"add a 4px border\" or \"make the canvas 32x32 but keep the sprite as is\".",
      inputSchema: {
        type: "object",
        properties: {
          width: {
            type: "integer"
          },
          height: {
            type: "integer"
          },
          anchor: {
            type: "string",
            enum: ["center","top-left","top-right","bottom-left","bottom-right"],
            description: "where the existing content sits inside the new canvas; default center"
          },
          label: {
            type: "string"
          }
        },
        required: ["width","height"]
      },
      async run(ctx, input) {

        return await ctx.session.request('canvas_size', {
          label: input.label || 'canvas ' + input.width + 'x' + input.height,
          width: input.width, height: input.height, anchor: input.anchor,
        });
      },
    },
  ],
};
