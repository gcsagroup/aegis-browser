#!/usr/bin/env node
try {
  const raw = process.env.REQUIRED_RESULTS;
  if (!raw) throw new Error('REQUIRED_RESULTS is missing');
  const results = JSON.parse(raw);
  if (!results || Array.isArray(results) || typeof results !== 'object') {
    throw new Error('REQUIRED_RESULTS must be a JSON object');
  }
  if (JSON.stringify(Object.keys(results)) !== JSON.stringify(['quality'])) {
    throw new Error('REQUIRED_RESULTS must contain exactly quality');
  }
  const failures = Object.entries(results)
    .filter(([, result]) => result !== 'success')
    .map(([name, result]) => `${name}=${result || 'missing'}`);
  if (Object.keys(results).length === 0) failures.push('no required jobs declared');
  if (failures.length > 0) throw new Error(`Required jobs did not succeed: ${failures.join(', ')}`);
  console.log(`Required jobs succeeded: ${Object.keys(results).join(', ')}`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
