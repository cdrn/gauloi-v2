export const ProofResolverAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_verifier",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_escrow",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "configureCorridor",
    "inputs": [
      {
        "name": "destinationChainId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "registry",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "fillsSlot",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "corridors",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "registry",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "fillsSlot",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "configured",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "escrow",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract GauloiEscrow"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "fillStorageSlot",
    "inputs": [
      {
        "name": "intentId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "filler",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "fillsSlot",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "resolve",
    "inputs": [
      {
        "name": "intentId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "order",
        "type": "tuple",
        "internalType": "struct DataTypes.Order",
        "components": [
          {
            "name": "taker",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "inputToken",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "inputAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "outputToken",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "minOutputAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "destinationChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "destinationAddress",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "expiry",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "nonce",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      },
      {
        "name": "evidence",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "enum IResolver.Verdict"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "setVerifier",
    "inputs": [
      {
        "name": "_verifier",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "verifier",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IFillProofVerifier"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "CorridorConfigured",
    "inputs": [
      {
        "name": "destinationChainId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "registry",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "fillsSlot",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "VerifierUpdated",
    "inputs": [
      {
        "name": "oldVerifier",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newVerifier",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  }
] as const;
