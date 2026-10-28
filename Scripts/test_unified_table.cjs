const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Resources/TopWeb/top.js'), 'utf8');
const render = source.slice(source.indexOf('  function renderLiveTable()'), source.indexOf('  function applyLiveFrame('));
const host = {pid: 28, command: 'Mac process', user: 'marcus', cpu: 8, memoryKB: 10, cpuTimeMS: 90};
let containers = [{key: 'docker:website:28:100', pid: 28, command: 'ruby3.3', user: 'root', cpu: 3,
 memoryKB: 200, cpuTimeMS: 1000, threads: 4, environment: {environment: 'My Websites'}}];
let applied, notice;
const state = {historical:false, search:'', sort:'cpu', ascending:false, selectedPID:null,
 selection:{duration:60}, liveFrame:{entries:[host], metrics:{processCount:1,threadCount:2}}};
const context = vm.createContext({state, window:{topEnvironments:{containerRows:()=>containers,lookup:()=>null,error:()=>''}},
 visibleRange:()=>({start:0,end:20}),applyTableFrame:frame=>{applied=frame},updateMetrics(){},
 clearProcessSelection:()=>{state.selectedPID=null},setConnection:(kind,text)=>{notice=text}});
vm.runInContext(render,context);
const run=()=>vm.runInContext('renderLiveTable()',context);
run();
assert.equal(applied.total,2);assert.equal(new Set(applied.entries.map(p=>p.key)).size,2);
assert.equal(applied.entries[0].key,'host:28');
assert.equal(state.displayMetrics.processCount,2);assert.equal(state.displayMetrics.threadCount,6);
state.sort='memory';run();assert.equal(applied.entries[0].key,containers[0].key);
state.sort='cputime';run();assert.equal(applied.entries[0].key,containers[0].key);
state.search='my websites';run();assert.equal(applied.total,1);assert.equal(applied.entries[0].pid,28);
state.selectedPID=containers[0].key;containers=[];run();assert.equal(applied.total,0);assert.equal(state.selectedPID,null);
assert.equal(notice,'Live');
console.log('Unified table: colliding PIDs, CPU/memory/time sorting, container search, metrics, and process exit passed.');
