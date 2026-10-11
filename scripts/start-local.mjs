import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { mkdtemp, chmod, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';
import { authorizeDockerMutation, loopbackCreate, projectContainers, verifyContainer, verifyLocalStack } from './local-safety.mjs';

// Temporary Unix-socket adapter for the pinned CLI, not a network-accessible Docker proxy.
// Only the child CLI uses it. No credentials, Docker bodies, or CLI status keys are logged.
const root=fileURLToPath(new URL('../',import.meta.url));
assert.match(await readFile(join(root,'supabase/config.toml'),'utf8'),/^project_id = "housekeeping-local"$/m);
for(const container of projectContainers()) verifyContainer(container);
const endpoint=execFileSync('docker',['context','inspect','--format','{{.Endpoints.docker.Host}}'],{encoding:'utf8'}).trim();
assert(endpoint.startsWith('unix://'),'A local Unix-socket Docker context is required');
const upstreamSocket=endpoint.slice(7);
const directory=await mkdtemp(join(tmpdir(),'hk-docker-'));
await chmod(directory,0o700);
const socketPath=join(directory,'docker.sock');
const sockets=new Set();
let child;
let deadline;

async function inspect(path) {
  return new Promise((resolve,reject)=>{
    const request=http.get({socketPath:upstreamSocket,path},response=>{
      let data='';
      response.on('data',chunk=>data+=chunk);
      response.on('end',()=>{
        try { assert.equal(response.statusCode,200);resolve(JSON.parse(data)); } catch { reject(new Error('Local resource inspection failed')); }
      });
    });
    request.on('error',()=>reject(new Error('Local Docker unavailable')));
  });
}

const server=http.createServer(async (request,response)=>{
  try {
    let body;
    const headers={...request.headers};
    if(!['GET','HEAD'].includes(request.method)) {
      const chunks=[];
      let size=0;
      for await(const chunk of request) {
        size+=chunk.length;
        assert(size<=4*1024*1024,'Container request too large');
        chunks.push(chunk);
      }
      body=Buffer.concat(chunks);
      const isJSON=(request.headers['content-type'] ?? '').includes('application/json');
      const input=isJSON && body.length ? JSON.parse(body.toString()) : undefined;
      await authorizeDockerMutation(request.method,request.url,input,inspect);
      if(request.method==='POST' && /\/containers\/create(?:\?|$)/.test(request.url)) body=Buffer.from(JSON.stringify(loopbackCreate(input)));
      delete headers['transfer-encoding'];
      headers['content-length']=Buffer.byteLength(body);
    }
    const upstream=http.request({socketPath:upstreamSocket,path:request.url,method:request.method,headers},result=>{
      response.writeHead(result.statusCode,result.headers);
      result.pipe(response);
    });
    upstream.on('error',()=>{response.writeHead(502);response.end('Local Docker request failed');});
    if(body!==undefined) upstream.end(body); else request.pipe(upstream);
  } catch {
    response.writeHead(400);response.end('Refused unsafe local Docker request');
  }
});
server.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
// Docker exec/attach uses HTTP upgrade; forward this byte stream on the same private socket.
server.on('upgrade',async (request,socket,head)=>{
  try { await authorizeDockerMutation(request.method,request.url,undefined,inspect); }
  catch { socket.destroy();return; }
  const upstream=net.connect(upstreamSocket,()=>{
    upstream.write(`${request.method} ${request.url} HTTP/${request.httpVersion}\r\n`);
    for(let i=0;i<request.rawHeaders.length;i+=2) upstream.write(`${request.rawHeaders[i]}: ${request.rawHeaders[i+1]}\r\n`);
    upstream.write('\r\n');
    if(head.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  upstream.on('error',()=>socket.destroy());
  socket.on('error',()=>upstream.destroy());
  socket.on('close',()=>upstream.destroy());
});

try {
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(socketPath,resolve);});
  await chmod(socketPath,0o600);
  const env={...process.env,DOCKER_HOST:`unix://${socketPath}`};
  delete env.DOCKER_CONTEXT;
  delete env.DOCKER_TLS_VERIFY;
  delete env.DOCKER_CERT_PATH;
  console.log('Starting HouseKeeping with explicit loopback port bindings…');
  child=spawn(process.env.HK_SUPABASE_CLI || 'supabase',['start','-o','json'],{cwd:root,env,stdio:['ignore','ignore','ignore']});
  deadline=setTimeout(()=>child.kill('SIGTERM'),180000);
  const forwardSignal=()=>child.kill('SIGTERM');
  process.once('SIGINT',forwardSignal);
  process.once('SIGTERM',forwardSignal);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
  clearTimeout(deadline);
  assert.equal(code,0,'Local CLI startup failed; diagnostic bodies suppressed to protect credentials');
  const containers=verifyLocalStack();
  console.log(`PASS: ${containers.length} project containers verified; all published ports bind 127.0.0.1`);
} finally {
  clearTimeout(deadline);
  for(const socket of sockets) socket.destroy();
  await new Promise(resolve=>server.close(resolve));
  await rm(directory,{recursive:true,force:true});
}
