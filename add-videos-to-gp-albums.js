#!/usr/bin/env node
/**
 * add-videos-to-gp-albums.js
 * --------------------------------------------------------------------------
 * Thin launcher — ALL logic lives in add-to-gp-albums.js. This just flips on `--videos` so the one
 * script runs its video path: reads the videos manifest, drives video-aware result/checkbox locators,
 * and keeps its own progress + review files (gp-add-progress-videos.json / gp-manual-review-videos.txt)
 * so it can never disturb a photo run. Every other flag is forwarded unchanged.
 *
 *   node add-videos-to-gp-albums.js --only "Contributor Two"   # smallest video set — TEST FIRST (4)
 *   node add-videos-to-gp-albums.js --only "Contributor Four"
 *   node add-videos-to-gp-albums.js --only "Contributor Five"
 *   node add-videos-to-gp-albums.js                          # all video sets, smallest -> largest
 *
 * Equivalent to:  node add-to-gp-albums.js --videos [flags]
 * --------------------------------------------------------------------------
 */
if (!process.argv.includes('--videos')) process.argv.splice(2, 0, '--videos');
require('./add-to-gp-albums.js');
