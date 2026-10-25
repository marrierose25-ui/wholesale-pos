#!/usr/bin/env node
/**
 * Vercel CLI Deployment Script (Cross-Platform)
 * Usage: node deploy.cjs [project-path] [options]
 */
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const isWindows = os.platform() === 'win32';
const ALLOWED_COMMANDS = new Set(['vercel', 'npm', 'pnpm', 'yarn']);
function log(msg) { console.error(msg); }
function commandExists(cmd) {
  if (!ALLOWED_COMMANDS.has(cmd)) throw new Error(`Command not in whitelist: ${cmd}`);
  try {
    if (isWindows) { return spawnSync('where', [cmd], { stdio: 'ignore' }).status === 0; }
    return spawnSync('sh', ['-c', `command -v "$1"`, '--', cmd], { stdio: 'ignore' }).status === 0;
  } catch { return false; }
}
function getCommandOutput(cmd, args) {
  try {
    const r = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'], shell: isWindows });
    return r.status === 0 ? (r.stdout || '').trim() : null;
  } catch { return null; }
}
function parseArgs(args) {
  const result = { projectPath: '.', prod: true, yes: false, skipBuild: false };
  for (const arg of args) {
    if (arg === '--prod') result.prod = true;
    else if (arg === '--yes' || arg === '-y') result.yes = true;
    else if (arg === '--skip-build') result.skipBuild = true;
    else if (!arg.startsWith('-')) result.projectPath = arg;
    else { log(`Unknown option: ${arg}`); process.exit(1); }
  }
  return result;
}
function checkLoginStatus() {
  log('Checking login status...');
  try {
    const r = spawnSync('vercel', ['whoami'], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], shell: isWindows });
    const o = (r.stdout || '').trim();
    if (r.status === 0 && o && !o.includes('Error') && !o.includes('not logged in')) { log(`Logged in as: ${o}`); return true; }
  } catch {}
  return false;
}
function doDeploy(projectPath, options) {
  log('');
  log('Starting deployment...');
  const args = [];
  if (options.yes) args.push('--yes');
  if (options.prod) { args.push('--prod'); log('Deployment environment: Production (Public)'); }
  log(`Executing: vercel ${args.join(' ')}`);
  log('========================================');
  try {
    const result = spawnSync('vercel', args, {
      cwd: projectPath, encoding: 'utf8', stdio: ['inherit', 'pipe', 'pipe'],
      timeout: 300000, shell: isWindows,
    });
    const output = (result.stdout || '') + (result.stderr || '');
    log(output);
    if (result.status !== 0) throw new Error('Deployment command failed');
    const aliasedMatch = output.match(/Aliased:\s*(https:\/\/[a-zA-Z0-9.-]+\.vercel\.app)/i);
    const productionUrl = aliasedMatch ? aliasedMatch[1] : null;
    const deploymentMatch = output.match(/Production:\s*(https:\/\/[a-zA-Z0-9.-]+\.vercel\.app)/i);
    const deploymentUrl = deploymentMatch ? deploymentMatch[1] : null;
    // Generic "https://<name>.vercel.app" fallback (Ready message / alias line)
    const anyMatch = output.match(/https:\/\/[a-zA-Z0-9-]+\.vercel\.app/);
    const finalUrl = productionUrl || deploymentUrl || (anyMatch ? anyMatch[0] : null);
    log('');
    log('========================================');
    log('Deployment successful!');
    log('========================================');
    if (finalUrl) {
      log(`Your site is live! Visit: ${finalUrl}`);
      console.log(JSON.stringify({ status: 'success', url: finalUrl }));
    } else {
      console.log(JSON.stringify({ status: 'success', message: 'Deployment successful' }));
    }
  } catch (error) {
    log(error.message || '');
    log('Deployment failed');
    process.exit(1);
  }
}
function main() {
  log('========================================');
  log('Vercel CLI Project Deployment');
  log('========================================');
  const args = process.argv.slice(2);
  const options = parseArgs(args);
  if (!commandExists('vercel')) { log('Error: Vercel CLI not installed'); process.exit(1); }
  if (!checkLoginStatus()) { log('Error: Not logged in'); process.exit(1); }
  const projectPath = path.resolve(options.projectPath);
  if (!fs.existsSync(projectPath)) { log(`Error: path missing: ${projectPath}`); process.exit(1); }
  log(`Project path: ${projectPath}`);
  doDeploy(projectPath, options);
}
main();
