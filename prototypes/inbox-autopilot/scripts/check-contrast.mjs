const pairs = [
  ["Body text", "#667085", "#ffffff", 4.5],
  ["Primary action", "#ffffff", "#5b36e8", 4.5],
  ["Paused status", "#a65300", "#fff8e8", 4.5],
  ["Running status", "#18763a", "#eefaf2", 4.5],
  ["Waiting queue summary", "#ad5c00", "#ffffff", 4.5],
  ["Evidence text", "#5f6879", "#fcfdff", 4.5],
];

function luminance(hex) {
  const channels = [1, 3, 5].map((index) => Number.parseInt(hex.slice(index, index + 2), 16) / 255);
  const linear = channels.map((value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4));
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(foreground, background) {
  const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

let failed = false;
for (const [label, foreground, background, minimum] of pairs) {
  const ratio = contrast(foreground, background);
  console.log(`${ratio.toFixed(2)}:1  ${label}`);
  if (ratio < minimum) failed = true;
}

if (failed) process.exit(1);
