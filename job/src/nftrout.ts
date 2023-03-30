import { randomInt } from 'crypto';
import { promises as fs } from 'fs';

// @ts-expect-error missing declaration
import { main as fishdraw, draw_svg as toSvg } from './fishdraw';
import { decrypt, encrypt } from './esm';

const MAX_SEED = 4294967295; // 2^32-1

async function main(tokenId: string, inputsDir: string, outputsDir: string): Promise<void> {
  try {
    await fs.access(`${inputsDir}/left/trout.json`);
    nftrout(null, null, randomInt(0, MAX_SEED), tokenId);
    process.exit(0);
  } catch {}

  const left = await readMetadata(`${inputsDir}/left/trout.json`);
  const right = await readMetadata(`${inputsDir}/right/trout.json`);
  let seedBig = BigInt(left.seed) * 3n + BigInt(right.seed) * 5n + BigInt(randomInt(0, 64));
  let seed = Number(seedBig % BigInt(MAX_SEED));
  await nftrout(left.tokenId, right.tokenId, seed, tokenId);
}

async function readMetadata(filePath: string) {
  const troutMeta = JSON.parse(await fs.readFile(filePath, 'utf8'));
  if (typeof troutMeta.seed === 'number') return troutMeta;
  const { seed } = JSON.parse(Buffer.from(await decrypt(troutMeta.seed)).toString());
  troutMeta.seed = seed;
  return troutMeta;
}

async function nftrout<S extends string | null>(
  leftId: S,
  rightId: S,
  seed: number,
  tokenId: string,
) {
  const fishSvg = toSvg(fishdraw(seed));

  const troutDescriptor = {
    left: leftId,
    right: rightId,
    tokenId,
    seed: await encrypt(JSON.stringify({ seed })),
  };

  await Promise.all([
    fs.writeFile(`${outputsDir}/trout.svg`, fishSvg),
    fs.writeFile(`${outputsDir}/trout.json`, JSON.stringify(troutDescriptor)),
  ]);
}

let [_node, _thisfile, tokenId, inputsDir, outputsDir] = process.argv;

if (!tokenId) throw new Error('missing tokenId');

main(tokenId, inputsDir ?? '/inputs', outputsDir ?? '/outputs').catch((e) => console.error(e));
