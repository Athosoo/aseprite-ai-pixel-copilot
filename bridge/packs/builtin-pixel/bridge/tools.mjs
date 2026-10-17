// 图像矫正 —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。
// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。
export default {
  tools: [
    {
      name: "perfect_pixel",
      description: "Run Perfect Pixel Studio's core algorithm: detect the pixel grid of an image that only looks like pixel art (skewed cells, blurry edges) and resample it into true pixel art. source=\"active_canvas\" applies the result IN PLACE: the current document gains one new layer (named \"PP <w>x<h>\") holding the fixed image at (0,0); no existing pixel is touched, and if the result is larger than the canvas the canvas is grown (never cropped). The whole apply is one undo step and is snapshotted first, so rollback also works. source=\"uploaded\" (fixing a picture the user dropped in) opens the result as a NEW preview document and also leaves an \"Apply this result\" button in the panel for the user to drop it onto whatever document is active later. If automatic detection fails, retry with an explicit gridSize such as [32,32]. Read the returned \"applied\" / \"openedDoc\" fields to describe what really happened instead of guessing.",
      inputSchema: {
        type: "object",
        properties: {
          source: {
            type: "string",
            enum: ["uploaded","active_canvas"],
            description: "which image to fix, default uploaded"
          },
          gridSize: {
            type: "array",
            description: "explicit grid size [w,h], e.g. [32,32]; omit for automatic detection",
            items: {
              type: "integer"
            }
          },
          sampleMethod: {
            type: "string",
            enum: ["center","median","majority"],
            description: "sampling method, default center (highest fidelity, byte-identical to the official Python port)"
          },
          fixSquare: {
            type: "boolean",
            description: "force square output when nearly square, default true"
          }
        },
        required: []
      },
      async run(ctx, input) {

        const source = input.source || 'uploaded';
        // 落地方式：active = 就地贴进当前文档的新图层（只可能来自 active_canvas）；
        // preview = 开预览文档（上传图，或扩展侧发现没有可用文档时自己退回这一档）
        let buf, w, h, note, sourceKey, target, label;
        if (source === 'uploaded') {
          if (!ctx.session.upload) {
            return { error: 'No image has been uploaded yet. Pick a file in the panel and click "Fix Image".' };
          }
          ({ buf, w, h } = ctx.session.upload);
          note = 'from upload ' + ctx.session.upload.name;
          sourceKey = 'upload:' + ctx.session.upload.name;
          target = 'preview';
          label = 'PP ' + ctx.session.upload.name;
        } else {
          const got = await ctx.session.request('get_canvas');
          if (got.error) return got;
          buf = got.buf;
          w = got.width;
          h = got.height;
          note = 'from the active canvas';
          sourceKey = 'canvas:' + w + 'x' + h;
          target = 'active';
          label = 'fixed image';
        }

        // 同一轮里已经矫正过这个来源了 —— 模型在复读，别再开一个文档（P8）
        if (ctx.session.turnProcessed?.has(sourceKey)) {
          return {
            alreadyProcessed: true,
            note: 'This source was already corrected in this turn. Do not run perfect_pixel again -- report the result you already have.',
          };
        }

        const res = await ctx.perfectPixel(ctx.bundlePath, buf, w, h, {
          sampleMethod: input.sampleMethod,
          gridSize: input.gridSize,
          fixSquare: input.fixSquare,
        });

        // 不同颜色数：既是 P9 的诊断数据，也是判断"是不是像素画"的便宜信号
        const distinctColors = ctx.countDistinctColors(buf);

        if (!res.detected) {
          // 检测不出来最常见的原因不是"图坏了"，而是**它本来就是 1:1 的像素画**：
          // detectGridScale 只找 >=4 倍的上采样因子（minSize=4），1px 一格时
          // 梯度峰值间距太小，直接判定"无网格"。这正是用户反馈的
          // 「已经处理过的图还会被再次处理」的根源 —— 模型看到 hint 就盲目重试 gridSize，
          // 结果开出一个和输入一模一样的文档。
          // 所以这里改成：**明确告诉模型别盲目重试**，只有用户点了逻辑尺寸才重试。
          ctx.session.turnProcessed?.add(sourceKey);
          return {
            detected: false,
            noGridDetected: true,
            input: w + 'x' + h,
            distinctColors,
            reason: res.message,
            note: 'No pixel grid detected. Detection only finds upscale factors of 4x or more, so an image that is ALREADY at 1:1 pixel size (typical for anything previously corrected) reports no grid here. Unless the user asked for a specific logical size, tell them it needs no processing and stop -- do NOT retry with gridSize. Retry with gridSize ONLY when the user names the size they want.',
          };
        }

        // 幂等（P8）：网格 == 图片尺寸 => 每格恰好 1px => 输出和输入逐字节相同。
        // 这时"矫正"是恒等变换，导入只会开出一个一模一样的文档，所以**不导入**。
        if (res.gridW === w && res.gridH === h) {
          ctx.session.turnProcessed?.add(sourceKey);
          return {
            detected: true,
            alreadyPerfect: true,
            input: w + 'x' + h,
            grid: w + 'x' + h,
            distinctColors,
            note: 'This image is already true pixel art (every grid cell is exactly 1px), so the correction would be a no-op. Tell the user it needs no processing and move on -- do NOT retry with gridSize.',
          };
        }

        ctx.session.turnProcessed?.add(sourceKey);
        const placed = await ctx.session.sendImport(res.data, res.outWidth, res.outHeight, note, { target, label });

        // 诊断（P9）：把四组尺寸推到面板，用户觉得结果不对时可以直接截图
        ctx.session.say?.('info', 'perfect_pixel: input=' + res.inputWidth + 'x' + res.inputHeight +
          ' grid=' + res.gridW + 'x' + res.gridH + ' refined=' + res.refinedW + 'x' + res.refinedH +
          ' output=' + res.outWidth + 'x' + res.outHeight + ' sample=' + (input.sampleMethod || 'center') +
          ' colors=' + distinctColors);

        const out = {
          detected: true,
          input: res.inputWidth + 'x' + res.inputHeight,
          grid: res.gridW + 'x' + res.gridH,
          refined: res.refinedW + 'x' + res.refinedH,
          output: res.outWidth + 'x' + res.outHeight,
          distinctColors,
        };

        // 落地结果：note 必须如实描述发生了什么，别让模型猜（也别再一律说"开了新文档"）
        if (placed && placed.applied) {
          out.applied = true;
          out.layer = placed.layer || null;
          out.canvas = placed.canvas || null;
          out.expanded = !!placed.expanded;
          if (placed.expanded) out.canvasWas = placed.canvasFrom || null;
          out.note =
            'Applied in place: added layer "' + placed.layer + '" with the ' + res.outWidth + 'x' + res.outHeight + ' fixed image at (0,0) ' +
            'of the active document' +
            (placed.expanded
              ? ', growing its canvas from ' + placed.canvasFrom + ' to ' + placed.canvas + ' after EXTENDING the canvas' +
                ' (nothing was cropped).'
              : ' (canvas stayed ' + placed.canvas + ').') +
            ' No existing pixel changed, the apply is one undo step, and a snapshot was taken first so rollback works. ' +
            'Report this to the user as done in their current document -- do NOT tell them to open or copy from another document.';
        } else if (placed && placed.applied === false && placed.reason === 'no-document') {
          out.applied = false;
          out.openedDoc = true;
          out.pendingApply = true;
          out.note =
            'No document was open, so the ' + res.outWidth + 'x' + res.outHeight + ' result was opened as a new document instead. ' +
            'It is also held as a pending result: once the user has a document open, the panel shows an "Apply this result" button that drops it in as a new layer. ' +
            'Tell the user to open their artwork and click that button -- do not tell them to copy pixels by hand.';
        } else {
          out.applied = false;
          out.openedDoc = true;
          out.pendingApply = !!(placed && placed.pending);
          out.note =
            'Opened as a new ' + res.outWidth + 'x' + res.outHeight + ' document so the user can copy from it. ' +
            "It is also held as a pending result: the panel's \"Apply this result\" button drops it into the active document as a new layer " +
            '(canvas grown if needed, existing pixels untouched). ' +
            "Say that the result is ready to be applied -- do not claim the user's canvas was already changed.";
        }
        if (placed && placed.error) out.applyError = String(placed.error);
        return out;
      },
    },
  ],
};
