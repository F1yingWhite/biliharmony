const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(process.env.ARKTS_TEST_SOURCE_ROOT || path.join(__dirname, '../../entry/src/main/ets'));

function modules(directory) {
  return fs.readdirSync(directory, {withFileTypes:true}).flatMap(entry => {
    const file=path.join(directory,entry.name);
    return entry.isDirectory()?modules(file):/\.(ets|ts)$/.test(entry.name)?[file]:[];
  });
}
const graph = new Map();
const missing = [];
for (const file of modules(root)) {
  const dependencies=[];
  const text=fs.readFileSync(file,'utf8');
  for(const match of text.matchAll(/(?:\bfrom\s+|\bimport\s*)['"]([^'"]+)['"]/g)) {
    if(!match[1].startsWith('.'))continue;
    const base=path.resolve(path.dirname(file),match[1]);
    const target=[base,base+'.ets',base+'.ts',path.join(base,'index.ets')].find(p=>fs.existsSync(p)&&fs.statSync(p).isFile());
    if(!target)missing.push(path.relative(root,file)+' → '+match[1]);
    else if(/\.(ets|ts)$/.test(target))dependencies.push(target);
  }
  graph.set(file,dependencies);
}
const relative=file=>path.relative(root,file).replaceAll('\\','/');

test('architecture: every relative production import resolves',()=>{
  assert.deepEqual(missing,[]);
});

test('architecture: production modules have no static import cycles',()=>{
  const visited=new Set(),active=new Set(),stack=[],cycles=[];
  function visit(file) {
    if(active.has(file)){cycles.push([...stack.slice(stack.indexOf(file)),file].map(relative).join(' → '));return;}
    if(visited.has(file))return;
    active.add(file);stack.push(file);
    for(const dependency of graph.get(file)||[])visit(dependency);
    stack.pop();active.delete(file);visited.add(file);
  }
  for(const file of graph.keys())visit(file);
  assert.deepEqual(cycles,[]);
});

test('architecture: models and services do not depend on views or components',()=>{
  const violations=[];
  for(const [file,dependencies] of graph){
    if(!/^(model|services)\//.test(relative(file)))continue;
    for(const target of dependencies){
      if(/^(pages|views|components)\//.test(relative(target)))violations.push(relative(file)+' → '+relative(target));
    }
  }
  assert.deepEqual(violations,[]);
});

test('architecture: reusable components never import a routed page',()=>{
  const violations=[];
  for(const [file,dependencies] of graph){
    if(!relative(file).startsWith('components/'))continue;
    for(const target of dependencies){
      if(/^(pages|views)\//.test(relative(target)))violations.push(relative(file)+' → '+relative(target));
    }
  }
  assert.deepEqual(violations,[]);
});
