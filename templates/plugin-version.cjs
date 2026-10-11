#!/usr/bin/env node
// #490: the plugin-version probe command, as a short script run by path (the probe agent copies a base64 of
// `node '<root>/templates/plugin-version.cjs'`, not of an inline program). Reads this plugin's manifest and
// prints exactly one line: PLUGIN-VERSION:<version> or PLUGIN-VERSION-ERROR:<no-version|missing|unreadable>.
// Never prints the plugin root path (the scrub hook refuses local paths in GitHub text).
'use strict'
const fs = require('fs')
const path = require('path')
try {
  const v = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '.claude-plugin', 'plugin.json'), 'utf8')).version
  console.log(typeof v === 'string' && v ? 'PLUGIN-VERSION:' + v : 'PLUGIN-VERSION-ERROR:no-version')
} catch (error) {
  console.log('PLUGIN-VERSION-ERROR:' + (error && error.code === 'ENOENT' ? 'missing' : 'unreadable'))
}
