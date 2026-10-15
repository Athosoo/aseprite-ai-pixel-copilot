// memory.mjs 的单元测试（不联网、不碰 Aseprite）。
//
//   cd bridge && node test/memory_test.mjs
//
// 重点验的是"别吃 token"那几条设计：单条截断、总量淘汰、按需检索、
// 以及"越用越留得住"（usedCount）。

import { Memory } from '../src/memory.mjs';
import { rmSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + extra : '')); }
};

const dir = mkdtempSync(join(tmpdir(), 'memtest-'));
const file = join(dir, 'memory.json');
const mem = new Memory(file);

console.log('== 存与取 ==');
{
  const r = mem.remember({ kind: 'style', text: '外壳一律用 1px 深色描边', tags: ['描边', '外壳'] });
  ok(r.ok === true, '写入成功');
  ok(typeof r.id === 'string' && r.id.length > 0, '返回了 id');
  ok(mem.size === 1, '库里有 1 条');

  const got = mem.recall({ query: '描边' });
  ok(got.returned === 1, '按关键词能召回，实际 ' + got.returned);
  ok(got.entries[0].text.includes('1px'), '召回内容正确');
  ok(got.entries[0].kind === 'style', 'kind 保留');
}

console.log('== 去重 ==');
{
  const before = mem.size;
  const r = mem.remember({ kind: 'style', text: '外壳一律用 1px 深色描边', tags: ['新标签'] });
  ok(r.updated === true, '同 kind 同正文 = 合并而不是新增');
  ok(mem.size === before, '总数没涨，仍是 ' + mem.size);
  const got = mem.recall({ query: '描边' });
  ok(got.entries[0].tags.includes('新标签') && got.entries[0].tags.includes('描边'),
     '标签合并了，实际 ' + JSON.stringify(got.entries[0].tags));
}

console.log('== 按 kind 过滤 ==');
{
  mem.remember({ kind: 'preference', text: '用户偏好冷色调', tags: ['配色'] });
  mem.remember({ kind: 'project', text: '项目是 16x16 图标集', tags: ['尺寸'] });
  ok(mem.recall({ kind: 'preference' }).returned === 1, 'kind=preference 只回 1 条');
  ok(mem.recall({ kind: 'project' }).returned === 1, 'kind=project 只回 1 条');
  ok(mem.recall({}).returned === 3, '不带条件 = 全回（3 条），实际 ' + mem.recall({}).returned);
}

console.log('== 标签是"必须命中"而不是加分 ==');
{
  const r = mem.recall({ tags: ['不存在的标签'] });
  ok(r.returned === 0, '不存在的标签 -> 0 条，实际 ' + r.returned);
}

console.log('== 单条截断（防灌长文）==');
{
  const long = 'x'.repeat(5000);
  const r = mem.remember({ kind: 'note', text: long });
  ok(r.truncated === true, '标记了 truncated');
  const got = mem.recall({ query: 'xxxx' });
  ok(got.entries[0].text.length === 400, '正文被截到 400 字，实际 ' + got.entries[0].text.length);
}

console.log('== 越用越留得住（usedCount）==');
{
  const m2 = new Memory(join(dir, 'memory2.json'));
  // 写 1 条"常用的"和 1 条"没碰过的"
  const hot = m2.remember({ kind: 'note', text: '常用的那条', tags: ['hot'] }).id;
  m2.remember({ kind: 'note', text: '没人碰的那条', tags: ['cold'] });
  for (let i = 0; i < 3; i++) m2.recall({ query: '常用的' });   // 刷使用次数
  const top = m2.list({ limit: 1 }).entries[0];
  ok(top.id === hot, 'list 按 usedCount 排序，最常用的排第一');
  ok(top.text === '常用的那条', '确实是常用的那条');
}

console.log('== 空查询也能按最近常用取 ==');
{
  const r = mem.recall({});
  ok(r.returned > 0, '无参数 recall 有返回（供"你还记得什么"这类问法）');
}

console.log('== forget ==');
{
  const r = mem.remember({ kind: 'note', text: '待删除的' });
  const del = mem.forget({ id: r.id });
  ok(del.ok === true, '删除成功');
  ok(mem.recall({ query: '待删除' }).returned === 0, '删完就召不回来了');
  ok(mem.forget({ id: 'nope' }).error !== undefined, '删不存在的 id 返回 error');
}

console.log('== 落盘 / 重新加载 ==');
{
  const m3 = new Memory(file);
  ok(m3.size === mem.size, `重新加载后条数一致（${m3.size}）`);
  ok(m3.recall({ query: '描边' }).returned === 1, '重新加载后还能召回');
}

rmSync(dir, { recursive: true, force: true });
console.log(`\n==== memory_test: ${pass} 通过, ${fail} 失败 ====`);
process.exit(fail === 0 ? 0 : 1);
