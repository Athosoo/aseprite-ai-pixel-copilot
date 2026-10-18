/** 算子清单的文本化与工具说明生成 —— 不依赖 dsh，可单测。 */

/** 冲突提示：batch 写盘成功，但 GUI 里打开的那份不会自动重载（实测 1.3.18.6-dev）。 */
export const STALE_HINT =
  'note: the file on disk is now updated. If it is open in Aseprite, use File > Revert before you do anything else — ' +
  'saving from that old window (Ctrl+S) would overwrite this change.';

/** 参数摘要：amount:number=1.3, region:region */
export function paramSummary(p) {
  let s = p.name + ':' + p.type;
  if (p.required) s += '!';
  if (p.default !== undefined) s += '=' + p.default;
  return s;
}

/** 算子清单的文本形式（同时用于工具说明与 aseprite_ops 的输出）。 */
export function manifestText(manifest) {
  return (manifest || []).map((e) => {
    const ps = (e.params || []).map(paramSummary).join(', ');
    return '- ' + e.name + ': ' + e.desc + (ps ? '  [params: ' + ps + ']' : '');
  }).join('\n');
}

/** aseprite_apply 的工具说明：把算子清单内嵌进去（决策 R1-C：比 10 个独立工具便宜）。 */
export function applyDescription(manifest) {
  return 'Apply canvas operations to a sprite file and save the result. Relative paths resolve against the workspace. ' +
    'The existing target file is backed up first; if the backup fails nothing is changed. Available operators:\n' +
    manifestText(manifest);
}
