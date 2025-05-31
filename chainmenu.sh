#!/bin/bash
# Bash script with menu for various blockchain CLI operations
# Allows user to specify the CLI binary (e.g., junkcoin-cli)

# Prompt for CLI binary
read -p "Enter the blockchain CLI binary (e.g., junkcoin-cli): " CLI_BINARY
if [ -z "$CLI_BINARY" ]; then
  echo "Error: No CLI binary specified. Exiting..."
  exit 1
fi

# Test if the binary is accessible
if ! command -v "./$CLI_BINARY" &> /dev/null; then
  echo "Error: CLI binary '$CLI_BINARY' not found or not executable. Exiting..."
  exit 1
fi

# Function for getblockchaininfo
get_blockchain_info() {
  echo "=== Get Blockchain Info ==="
  echo "Fetching blockchain information..."
  RESULT=$("./$CLI_BINARY" getblockchaininfo)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve blockchain info."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getblockcount
get_block_count() {
  echo "=== Get Block Count ==="
  echo "Fetching current block count..."
  RESULT=$("./$CLI_BINARY" getblockcount)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve block count."
    return 1
  fi
  echo "Current block height: $RESULT"
}

# Function for getbestblockhash
get_best_block_hash() {
  echo "=== Get Best Block Hash ==="
  echo "Fetching hash of the best block..."
  RESULT=$("./$CLI_BINARY" getbestblockhash)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve best block hash."
    return 1
  fi
  echo "Best block hash: $RESULT"
}

# Function for getblock
get_block() {
  echo "=== Get Block ==="
  read -p "Enter block hash: " BLOCK_HASH
  read -p "Enter verbosity level (0 for hex, 1 for JSON, 2 for detailed JSON): " VERBOSITY
  echo "Fetching block data for hash $BLOCK_HASH..."
  RESULT=$("./$CLI_BINARY" getblock "$BLOCK_HASH" "$VERBOSITY")
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve block data."
    return 1
  fi
  if [ "$VERBOSITY" -eq 0 ]; then
    echo "Raw block hex: $RESULT"
  else
    echo "$RESULT" | jq .  # Pretty-print JSON
  fi
}

# Function for getblockhash
get_block_hash() {
  echo "=== Get Block Hash ==="
  read -p "Enter block height: " HEIGHT
  echo "Fetching block hash for height $HEIGHT..."
  RESULT=$("./$CLI_BINARY" getblockhash "$HEIGHT")
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve block hash."
    return 1
  fi
  echo "Block hash at height $HEIGHT: $RESULT"
}

# Function for getdifficulty
get_difficulty() {
  echo "=== Get Difficulty ==="
  echo "Fetching current network difficulty..."
  RESULT=$("./$CLI_BINARY" getdifficulty)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve difficulty."
    return 1
  fi
  echo "Current difficulty: $RESULT"
}

# Function for getmempoolinfo
get_mempool_info() {
  echo "=== Get Mempool Info ==="
  echo "Fetching mempool information..."
  RESULT=$("./$CLI_BINARY" getmempoolinfo)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve mempool info."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getrawmempool
get_raw_mempool() {
  echo "=== Get Raw Mempool ==="
  read -p "Enter verbosity (0 for transaction IDs, 1 for detailed JSON): " VERBOSITY
  echo "Fetching raw mempool data..."
  RESULT=$("./$CLI_BINARY" getrawmempool "$VERBOSITY")
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve raw mempool."
    return 1
  fi
  if [ "$VERBOSITY" -eq 0 ]; then
    echo "Transaction IDs in mempool: $RESULT"
  else
    echo "$RESULT" | jq .  # Pretty-print JSON
  fi
}

# Function for gettxout
get_tx_out() {
  echo "=== Get Transaction Output ==="
  read -p "Enter transaction ID (txid): " TXID
  read -p "Enter output index (vout): " VOUT
  read -p "Include mempool? (true/false): " INCLUDE_MEMPOOL
  echo "Fetching transaction output for txid $TXID, vout $VOUT..."
  RESULT=$("./$CLI_BINARY" gettxout "$TXID" "$VOUT" "$INCLUDE_MEMPOOL")
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve transaction output or not found."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for gettxoutsetinfo
get_tx_out_set_info() {
  echo "=== Get Transaction Output Set Info ==="
  echo "Fetching UTXO set statistics..."
  RESULT=$("./$CLI_BINARY" gettxoutsetinfo)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve UTXO set info."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getnetworkinfo
get_network_info() {
  echo "=== Get Network Info ==="
  echo "Fetching network information..."
  RESULT=$("./$CLI_BINARY" getnetworkinfo)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve network info."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getpeerinfo
get_peer_info() {
  echo "=== Get Peer Info ==="
  echo "Fetching connected peers information..."
  RESULT=$("./$CLI_BINARY" getpeerinfo)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve peer info."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getmininginfo
get_mining_info() {
  echo "=== Get Mining Info ==="
  echo "Fetching mining information..."
  RESULT=$("./$CLI_BINARY" getmininginfo)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve mining info."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getblockstats
get_block_stats() {
  echo "=== Get Block Stats ==="
  read -p "Enter block hash or height: " BLOCK_ID
  echo "Fetching block statistics for $BLOCK_ID..."
  RESULT=$("./$CLI_BINARY" getblockstats "$BLOCK_ID")
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve block stats."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getchaintips
get_chain_tips() {
  echo "=== Get Chain Tips ==="
  echo "Fetching chain tips..."
  RESULT=$("./$CLI_BINARY" getchaintips)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve chain tips."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getmempoolentry
get_mempool_entry() {
  echo "=== Get Mempool Entry ==="
  read -p "Enter transaction ID (txid): " TXID
  echo "Fetching mempool entry for txid $TXID..."
  RESULT=$("./$CLI_BINARY" getmempoolentry "$TXID")
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve mempool entry or txid not found."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Function for getchainstate
get_chain_state() {
  echo "=== Get Chain State ==="
  echo "Fetching chain state information..."
  RESULT=$("./$CLI_BINARY" getchainstate)
  if [ -z "$RESULT" ]; then
    echo "Error: Failed to retrieve chain state. Command may not be supported."
    return 1
  fi
  echo "$RESULT" | jq .  # Pretty-print JSON
}

# Main menu
while true; do
  echo "=== Blockchain CLI Operations Menu (Using $CLI_BINARY) ==="
  echo "1. Get Blockchain Info (getblockchaininfo)"
  echo "2. Get Block Count (getblockcount)"
  echo "3. Get Best Block Hash (getbestblockhash)"
  echo "4. Get Block (getblock)"
  echo "5. Get Block Hash (getblockhash)"
  echo "6. Get Difficulty (getdifficulty)"
  echo "7. Get Mempool Info (getmempoolinfo)"
  echo "8. Get Raw Mempool (getrawmempool)"
  echo "9. Get Transaction Output (gettxout)"
  echo "10. Get UTXO Set Info (gettxoutsetinfo)"
  echo "11. Get Network Info (getnetworkinfo)"
  echo "12. Get Peer Info (getpeerinfo)"
  echo "13. Get Mining Info (getmininginfo)"
  echo "14. Get Block Stats (getblockstats)"
  echo "15. Get Chain Tips (getchaintips)"
  echo "16. Get Mempool Entry (getmempoolentry)"
  echo "17. Get Chain State (getchainstate)"
  echo "18. Exit"
  read -p "Select an option (1-18): " OPTION

  case $OPTION in
    1)
      get_blockchain_info
      ;;
    2)
      get_block_count
      ;;
    3)
      get_best_block_hash
      ;;
    4)
      get_block
      ;;
    5)
      get_block_hash
      ;;
    6)
      get_difficulty
      ;;
    7)
      get_mempool_info
      ;;
    8)
      get_raw_mempool
      ;;
    9)
      get_tx_out
      ;;
    10)
      get_tx_out_set_info
      ;;
    11)
      get_network_info
      ;;
    12)
      get_peer_info
      ;;
    13)
      get_mining_info
      ;;
    14)
      get_block_stats
      ;;
    15)
      get_chain_tips
      ;;
    16)
      get_mempool_entry
      ;;
    17)
      get_chain_state
      ;;
    18)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo "Invalid option. Please select 1-18."
      ;;
  esac
  echo
done
