import { useSignTypedData } from "wagmi";
import { keccak256, encodeAbiParameters } from "viem";
import { ORDER_TYPES, type OrderMessage } from "@gauloi/common";

function orderDomain(escrowAddress: `0x${string}`, chainId: number) {
  return {
    name: "GauloiEscrow" as const,
    version: "1" as const,
    chainId,
    verifyingContract: escrowAddress,
  };
}

function generateNonce(): bigint {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return BigInt("0x" + Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join(""));
}

function computeIntentId(order: OrderMessage): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
      ],
      [
        order.taker,
        order.inputToken,
        order.inputAmount,
        order.outputToken,
        order.minOutputAmount,
        order.destinationChainId,
        order.destinationAddress,
        order.expiry,
        order.nonce,
      ],
    ),
  );
}

interface SignOrderParams {
  taker: `0x${string}`;
  inputToken: `0x${string}`;
  inputAmount: bigint;
  outputToken: `0x${string}`;
  minOutputAmount: bigint;
  destinationChainId: number;
  destinationAddress: `0x${string}`;
  expirySeconds: number;
  escrowAddress: `0x${string}`;
  chainId: number;
}

export function useSignOrder() {
  const { signTypedDataAsync, isPending } = useSignTypedData();

  const sign = async (params: SignOrderParams) => {
    const nonce = generateNonce();
    const expiry = BigInt(Math.floor(Date.now() / 1000) + params.expirySeconds);

    const order: OrderMessage = {
      taker: params.taker,
      inputToken: params.inputToken,
      inputAmount: params.inputAmount,
      outputToken: params.outputToken,
      minOutputAmount: params.minOutputAmount,
      destinationChainId: BigInt(params.destinationChainId),
      destinationAddress: params.destinationAddress,
      expiry,
      nonce,
    };

    const intentId = computeIntentId(order);

    const signature = await signTypedDataAsync({
      domain: orderDomain(params.escrowAddress, params.chainId),
      types: ORDER_TYPES,
      primaryType: "Order",
      message: {
        taker: order.taker,
        inputToken: order.inputToken,
        inputAmount: order.inputAmount,
        outputToken: order.outputToken,
        minOutputAmount: order.minOutputAmount,
        destinationChainId: order.destinationChainId,
        destinationAddress: order.destinationAddress,
        expiry: order.expiry,
        nonce: order.nonce,
      },
    });

    return { order, intentId, signature, nonce, expiry };
  };

  return { sign, isPending };
}
