import { randomBytes } from 'crypto';

import * as sapphire from '@oasisprotocol/sapphire-paratime';
// @ts-expect-error missing declaration
import deoxysii from 'deoxysii';
import { ethers } from 'ethers';
import createKeccakHash from 'keccak';

import { AttestationToken, AttestationTokenFactory, Lockbox, LockboxFactory } from '@escrin/evm';

import { decode, encode, memoizeAsync } from './utils';

type Registration = AttestationToken.RegistrationStruct;

type InitOpts = {
  web3GatewayUrl: string;
  attokAddr: string;
  lockboxAddr: string;
};

export type Box = {
  keyId: number;
  nonce: string;
  data: string; // hex
};

export const LATEST_KEY_ID = 1;

export class ESM {
  public static INIT_SAPPHIRE: InitOpts = {
    web3GatewayUrl: 'https://sapphire.oasis.io',
    attokAddr: '0x127c49aE10e3c18be057106F4d16946E3Ae43975',
    lockboxAddr: '0x52892d19DeFDDE7C25504212B3bA8E99D8e0552e',
  };

  public static INIT_SAPPHIRE_TESTNET: InitOpts = {
    web3GatewayUrl: 'https://testnet.sapphire.oasis.dev',
    attokAddr: '0x3763c7364F3ba5DFc3DeBf428eB9ed49e5058bb5',
    lockboxAddr: '0x20F3FEa7798deAd509ffA7B222101682E61878D8',
  };

  private provider: ethers.providers.Provider;
  private attok: AttestationToken;
  private lockbox: Lockbox;
  private gasWallet: ethers.Wallet;
  private localWallet: ethers.Wallet;

  constructor(public readonly opts: InitOpts, gasKey: string) {
    console.log(opts);
    this.provider = new ethers.providers.JsonRpcProvider(opts.web3GatewayUrl);
    this.gasWallet = new ethers.Wallet(gasKey).connect(this.provider);
    this.localWallet = sapphire.wrap(ethers.Wallet.createRandom().connect(this.provider));
    this.attok = AttestationTokenFactory.connect(opts.attokAddr, this.localWallet).connect(
      this.gasWallet, // connect to the local wallet first to propagate sapphire wrapping
    );
    this.lockbox = LockboxFactory.connect(opts.lockboxAddr, this.localWallet);
  }

  private fetchKeySapphire = memoizeAsync(async () => {
    const oneHourFromNow = Math.floor(Date.now() / 1000) + 60 * 60;
    let currentBlock = await this.provider.getBlock('latest');
    const prevBlock = await this.provider.getBlock(currentBlock.number - 1);
    const registration: Registration = {
      baseBlockHash: prevBlock.hash,
      baseBlockNumber: prevBlock.number,
      expiry: oneHourFromNow,
      registrant: this.localWallet.address,
      tokenExpiry: oneHourFromNow,
    };
    const quote = await mockQuote(registration);
    const tcbId = await sendAttestation(this.attok, quote, registration);
    return getOrCreateKey(this.lockbox, this.gasWallet, tcbId);
  });

  private getCipher = memoizeAsync(async (keyId: number) => {
    let key;
    if (keyId === 0) key = Buffer.alloc(deoxysii.KeySize, 42);
    else if (keyId === 1) key = await this.fetchKeySapphire();
    else throw new Error(`unknown key: ${keyId}`);
    return new deoxysii.AEAD(key);
  });

  public async encrypt(data: Uint8Array): Promise<Box> {
    const keyId = LATEST_KEY_ID;
    const cipher = await this.getCipher(keyId);
    const nonce = randomBytes(deoxysii.NonceSize);
    return {
      keyId,
      nonce: encode(nonce),
      data: encode(cipher.encrypt(nonce, data)),
    };
  }

  public async decrypt({ keyId, nonce, data }: Box): Promise<Uint8Array> {
    const cipher = await this.getCipher(keyId);
    return cipher.decrypt(decode(nonce), decode(data));
  }
}

async function mockQuote(registration: Registration): Promise<Uint8Array> {
  const coder = ethers.utils.defaultAbiCoder;
  const measurementHash = '0xc275e487107af5257147ce76e1515788118429e0caa17c04d508038da59d5154'; // static random bytes. this is just a key in a key-value store.
  const regTypeDef =
    'tuple(uint256 baseBlockNumber, bytes32 baseBlockHash, uint256 expiry, uint256 registrant, uint256 tokenExpiry)'; // TODO: keep this in sync with the actual typedef
  const regBytesHex = coder.encode([regTypeDef], [registration]);
  const regBytes = Buffer.from(ethers.utils.arrayify(regBytesHex));
  return ethers.utils.arrayify(
    coder.encode(
      ['bytes32', 'bytes32'],
      [measurementHash, createKeccakHash('keccak256').update(regBytes).digest()],
    ),
  );
}

async function sendAttestation(
  attok: AttestationToken,
  quote: Uint8Array,
  reg: Registration,
): Promise<string> {
  const tx = await attok.attest(quote, reg, { gasLimit: 10_000_000 });
  console.log('attesting:', tx.hash);
  const receipt = await tx.wait();
  if (receipt.status !== 1) throw new Error('attestation tx failed');
  let tcbId = '';
  for (const event of receipt.events ?? []) {
    if (event.event !== 'Attested') continue;
    tcbId = event.args!.tcbId;
  }
  if (!tcbId) throw new Error('could not retrieve attestation id');
  console.log('received tcb:', tcbId);
  await waitForConfirmation(attok.provider, receipt);
  return tcbId;
}

async function waitForConfirmation(
  provider: ethers.providers.Provider,
  receipt: ethers.ContractReceipt,
): Promise<void> {
  const getCurrentBlock = () => provider.getBlock('latest');
  let currentBlock = await getCurrentBlock();
  while (currentBlock.number === receipt.blockNumber) {
    await new Promise((resolve) => setTimeout(resolve, 3_000));
    currentBlock = await getCurrentBlock();
  }
}

async function getOrCreateKey(
  lockbox: Lockbox,
  gasWallet: ethers.Wallet,
  tcbId: string,
): Promise<Uint8Array> {
  let key = await lockbox.callStatic.getKey(tcbId);
  if (!/^(0x)?0+$/.test(key)) return ethers.utils.arrayify(key);
  const tx = await lockbox
    .connect(gasWallet)
    .createKey(tcbId, randomBytes(32), { gasLimit: 10_000_000 });
  console.log('creating key:', tx.hash);
  const receipt = await tx.wait();
  await waitForConfirmation(lockbox.provider, receipt);
  key = await lockbox.callStatic.getKey(tcbId);
  return ethers.utils.arrayify(key);
}
