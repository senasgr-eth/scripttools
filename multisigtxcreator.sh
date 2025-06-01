#!/bin/bash
# Bash script with menu for creating, signing, broadcasting multisig P2SH transactions, and consolidating UTXOs using a configurable CLI binary
# Handles multiple UTXOs for sufficient funds with enhanced error checking, prioritization of largest UTXOs, and multisig validation
# Auto-signs transactions in create_send_transaction and consolidate_utxos, provides partially signed hex for other participants
# Broadcasts transaction directly without redeem script verification
# Uses predefined BINARY, P2SH_ADDRESS, REDEEM_SCRIPT, and PRIVATE_KEY if set, otherwise prompts for input
# Adds debug output for address validation and allows bypassing invalid address errors
# Displays balance and UTXO count for P2SH_ADDRESS above the menu on startup, with background fetching for performance

# Default variables (set these or leave empty to prompt)
BINARY="./junkcoin-cli"
P2SH_ADDRESS="34P2otqp4hUL4kRoVH74KpyrBdkrqZM18n"
REDEEM_SCRIPT="52210242a71da46329fa5cc0f600e5589181cdacbb99a6a9cd9cc349e9d96e6a601eb02103d57967f8cbf1592c45c60ade39274494bec4ba8ee538bab5ffb3eb2d023dbbe952ae"
PRIVATE_KEY=""

# Initialize balance and UTXO count
TOTAL_AMOUNT="Fetching..."
UTXO_COUNT="Fetching..."

# Prompt for BINARY if not set
if [ -z "$BINARY" ]; then
  read -p "Enter the CLI binary (e.g., junkcoin-cli, xbt-cli): " BINARY
  if [ -z "$BINARY" ]; then
    echo "Error: No binary provided. Exiting."
    exit 1
  fi
fi
echo "Using CLI binary: $BINARY"

# Function to fetch balance and UTXO count in the background
fetch_balance_utxos() {
  if [ -n "$P2SH_ADDRESS" ]; then
    # Validate address first
    VALIDATE=$($BINARY validateaddress "$P2SH_ADDRESS" 2>/dev/null)
    IS_VALID=$(echo "$VALIDATE" | jq -r '.isvalid')
    if [ "$IS_VALID" != "true" ]; then
      echo "Balance: Invalid P2SH address" > /tmp/balance_utxo_status
      echo "UTXOs: Invalid P2SH address" >> /tmp/balance_utxo_status
      return
    fi
    UTXOS=$($BINARY listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]" 2>/dev/null)
    if [ -n "$UTXOS" ] && [ "$UTXOS" != "[]" ]; then
      TOTAL_AMOUNT=$(echo "$UTXOS" | jq -r '.[] | .amount' | awk '{s+=$1} END {print s}' 2>/dev/null)
      UTXO_COUNT=$(echo "$UTXOS" | jq -r 'length' 2>/dev/null)
      if [ -z "$TOTAL_AMOUNT" ] || [ -z "$UTXO_COUNT" ]; then
        echo "Balance: Error fetching balance" > /tmp/balance_utxo_status
        echo "UTXOs: Error fetching UTXOs" >> /tmp/balance_utxo_status
      else
        echo "Balance: $TOTAL_AMOUNT" > /tmp/balance_utxo_status
        echo "UTXOs: $UTXO_COUNT" >> /tmp/balance_utxo_status
      fi
    else
      echo "Balance: 0" > /tmp/balance_utxo_status
      echo "UTXOs: 0" >> /tmp/balance_utxo_status
    fi
  else
    echo "Balance: N/A (No P2SH address set)" > /tmp/balance_utxo_status
    echo "UTXOs: N/A (No P2SH address set)" >> /tmp/balance_utxo_status
  fi
}

# Start background fetch
fetch_balance_utxos &

# Function to read balance and UTXO status
read_balance_utxos() {
  if [ -f /tmp/balance_utxo_status ]; then
    TOTAL_AMOUNT=$(grep "Balance:" /tmp/balance_utxo_status | cut -d':' -f2- | sed 's/^ *//')
    UTXO_COUNT=$(grep "UTXOs:" /tmp/balance_utxo_status | cut -d':' -f2- | sed 's/^ *//')
  fi
}

# Function to validate P2SH address with debug and bypass option
validate_p2sh_address() {
  local addr=$1
  VALIDATE=$($BINARY validateaddress "$addr" 2>/dev/null)
  IS_VALID=$(echo "$VALIDATE" | jq -r '.isvalid')
  echo "Debug: validateaddress output: $VALIDATE"
  if [ "$IS_VALID" != "true" ]; then
    echo "Warning: P2SH address $addr is invalid according to $BINARY."
    read -p "Proceed anyway? (y/n): " PROCEED
    if [ "$PROCEED" != "y" ]; then
      echo "Error: Invalid P2SH address. Aborting."
      return 1
    fi
  fi
  return 0
}

# Function to create a raw transaction and auto-sign
create_send_transaction() {
  echo "=== Create Send Transaction ==="
  
  # Use default P2SH_ADDRESS if set, otherwise prompt
  if [ -n "$P2SH_ADDRESS" ]; then
    echo "Using P2SH address: $P2SH_ADDRESS"
  else
    read -p "Enter P2SH address: " P2SH_ADDRESS
  fi
  
  # Use default REDEEM_SCRIPT if set, otherwise prompt
  if [ -n "$REDEEM_SCRIPT" ]; then
    echo "Using redeem script: $REDEEM_SCRIPT"
  else
    read -p "Enter redeem script: " REDEEM_SCRIPT
  fi
  
  read -p "Enter amount to send: " AMOUNT_TO_SEND
  read -p "Enter destination address: " DESTINATION_ADDRESS
  
  # Use default PRIVATE_KEY if set, otherwise prompt
  if [ -n "$PRIVATE_KEY" ]; then
    echo "Using private key: $PRIVATE_KEY"
  else
    read -p "Enter your private key: " PRIVATE_KEY
  fi

  # Validate P2SH address
  if ! validate_p2sh_address "$P2SH_ADDRESS"; then
    return 1
  fi

  # Validate redeem script
  SCRIPT_INFO=$($BINARY decodescript "$REDEEM_SCRIPT" 2>/dev/null)
  if [ -z "$SCRIPT_INFO" ] || [ "$(echo "$SCRIPT_INFO" | jq -r '.type')" != "multisig" ]; then
    echo "Error: Invalid or non-multisig redeem script."
    return 1
  fi
  REQSIGS=$(echo "$SCRIPT_INFO" | jq -r '.reqSigs')
  P2SH_CHECK=$(echo "$SCRIPT_INFO" | jq -r '.p2sh')
  if [ "$P2SH_CHECK" != "$P2SH_ADDRESS" ]; then
    echo "Error: Redeem script does not match P2SH address. Expected: $P2SH_CHECK"
    return 1
  fi
  echo "Redeem script is $REQSIGS-of-N multisig. $REQSIGS signatures required."

  # Check if private key is empty
  if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: No private key provided."
    return 1
  fi

  # Step 1: Check balance and get UTXOs, sorted by amount (largest first)
  echo "Checking unspent transactions for $P2SH_ADDRESS..."
  UTXOS=$($BINARY listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]" 2>/dev/null | jq 'sort_by(-.amount)')
  if [ -z "$UTXOS" ] || [ "$UTXOS" == "[]" ]; then
    echo "Error: No unspent transactions found for $P2SH_ADDRESS."
    return 1
  fi

  # Calculate total available amount from all UTXOs
  TOTAL_AMOUNT=$(echo "$UTXOS" | jq -r '.[] | .amount' | awk '{s+=$1} END {print s}')
  if [ -z "$TOTAL_AMOUNT" ]; then
    echo "Error: Unable to calculate total balance."
    return 1
  fi
  echo "Total available balance: $TOTAL_AMOUNT"

  # Step 2: Estimate fee (assuming 6 confirmations target)
  FEE_RATE=$($BINARY estimatefee 6 2>/dev/null)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0001"
    FEE_RATE=0.0001
  fi

  # Initial fee estimation (assume 250 bytes base, +100 bytes per extra input)
  UTXO_COUNT=$(echo "$UTXOS" | jq -r 'length')
  TX_SIZE=$((250 + 100 * (UTXO_COUNT - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)

  # Check if total amount is sufficient
  TOTAL_NEEDED=$(echo "$AMOUNT_TO_SEND + $FEE" | bc -l)
  if (( $(echo "$TOTAL_AMOUNT < $TOTAL_NEEDED" | bc -l) )); then
    echo "Error: Insufficient funds. Available: $TOTAL_AMOUNT, Requested: $AMOUNT_TO_SEND, Fee: $FEE"
    return 1
  fi

  # Step 3: Collect enough UTXOs, prioritizing largest values
  echo "Selecting UTXOs (largest first) to cover $TOTAL_NEEDED..."
  INPUTS=""
  SELECTED_AMOUNT=0
  INPUT_JSON="["
  SELECTED_COUNT=0

  for i in $(seq 0 $((UTXO_COUNT - 1))); do
    UTXO_AMOUNT=$(echo "$UTXOS" | jq -r ".[$i].amount")
    TXID=$(echo "$UTXOS" | jq -r ".[$i].txid")
    VOUT=$(echo "$UTXOS" | jq -r ".[$i].vout")
    SCRIPT_PUBKEY=$(echo "$UTXOS" | jq -r ".[$i].scriptPubKey")

    # Add this UTXO to inputs
    SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
    
    if [ -z "$INPUTS" ]; then
      INPUT_JSON="[{\"txid\":\"$TXID\", \"vout\":$VOUT}"
      INPUTS="{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    else
      INPUT_JSON="$INPUT_JSON,{\"txid\":\"$TXID\", \"vout\":$VOUT}"
      INPUTS="$INPUTS,{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    fi

    # Recalculate fee based on actual number of inputs used so far
    TX_SIZE=$((250 + 100 * (SELECTED_COUNT - 1)))
    FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)
    TOTAL_NEEDED=$(echo "$AMOUNT_TO_SEND + $FEE" | bc -l)

    # Check if we have enough
    if (( $(echo "$SELECTED_AMOUNT >= $TOTAL_NEEDED" | bc -l) )); then
      break
    fi
  done
  INPUT_JSON="$INPUT_JSON]"

  # Verify selected amount
  if (( $(echo "$SELECTED_AMOUNT < $TOTAL_NEEDED" | bc -l) )); then
    echo "Error: Unable to select enough UTXOs. Selected: $SELECTED_AMOUNT, Needed: $TOTAL_NEEDED"
    return 1
  fi

  # Calculate change
  CHANGE=$(echo "$SELECTED_AMOUNT - $AMOUNT_TO_SEND - $FEE" | bc -l)
  if (( $(echo "$CHANGE < 0" | bc -l) )); then
    echo "Error: Insufficient funds selected for amount + fee. Selected: $SELECTED_AMOUNT, Requested: $AMOUNT_TO_SEND, Fee: $FEE"
    return 1
  fi

  # Step 4: Create raw transaction
  echo "Creating raw transaction with $SELECTED_COUNT UTXOs..."
  RAW_TX=$($BINARY createrawtransaction "$INPUT_JSON" "{\"$DESTINATION_ADDRESS\":$AMOUNT_TO_SEND, \"$P2SH_ADDRESS\":$CHANGE}" 2>/dev/null)
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction. Check inputs or $BINARY."
    return 1
  fi

  # Step 5: Auto-sign with provided private key
  echo "Signing with private key (partial signature)..."
  SIGNED_TX=$($BINARY signrawtransaction "$RAW_TX" "[${INPUTS}]" "[\"$PRIVATE_KEY\"]" 2>/dev/null)
  if [ -z "$SIGNED_TX" ]; then
    echo "Error: Failed to sign transaction. Check private key, transaction hex, or inputs."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  # Decode signed transaction to count signatures
  DECODED=$($BINARY decoderawtransaction "$SIGNED_HEX" 2>/dev/null)
  if [ -z "$DECODED" ]; then
    echo "Error: Failed to decode signed transaction."
    return 1
  fi
  # Count signatures: look for hex strings of 60-144 bytes (DER signatures)
  SIG_COUNT=$(echo "$DECODED" | jq -r '.vin[].scriptSig.asm' | tr ' ' '\n' | grep -E '^[0-9a-fA-F]{60,144}$' | wc -l)

  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed with $SIG_COUNT signatures!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Use 'Broadcast Final Transaction' to send it."
  else
    echo "Partial signature complete. $SIG_COUNT of $REQSIGS signatures provided."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Inputs for signing: [$INPUTS]"
    echo "Share this hex and inputs with another signer to sign with their private key:"
    echo "$BINARY signrawtransaction \"$SIGNED_HEX\" \"[$INPUTS]\" \"[<private key 2>]\""
    if [ "$SIG_COUNT" -lt "$REQSIGS" ]; then
      echo "Warning: Still need $(($REQSIGS - $SIG_COUNT)) more signature(s) to complete!"
    fi
  fi
}

# Function to sign a partial transaction
sign_partial_tx() {
  echo "=== Sign Partial Transaction ==="
  
  # Use default P2SH_ADDRESS if set, otherwise prompt
  if [ -n "$P2SH_ADDRESS" ]; then
    echo "Using P2SH address: $P2SH_ADDRESS"
  else
    read -p "Enter P2SH address: " P2SH_ADDRESS
  fi
  
  # Use default REDEEM_SCRIPT if set, otherwise prompt
  if [ -n "$REDEEM_SCRIPT" ]; then
    echo "Using redeem script: $REDEEM_SCRIPT"
  else
    read -p "Enter redeem script: " REDEEM_SCRIPT
  fi
  
  read -p "Enter the partially signed transaction hex: " RAW_TX
  read -p "Enter the inputs JSON (from create step, e.g., [{\"txid\":..., \"vout\":...}]): " INPUTS
  
  # Use default PRIVATE_KEY if set, otherwise prompt
  if [ -n "$PRIVATE_KEY" ]; then
    echo "Using private key: $PRIVATE_KEY"
  else
    read -p "Enter your private key: " PRIVATE_KEY
  fi

  # Validate P2SH address
  if ! validate_p2sh_address "$P2SH_ADDRESS"; then
    return 1
  fi

  # Validate redeem script
  SCRIPT_INFO=$($BINARY decodescript "$REDEEM_SCRIPT" 2>/dev/null)
  if [ -z "$SCRIPT_INFO" ] || [ "$(echo "$SCRIPT_INFO" | jq -r '.type')" != "multisig" ]; then
    echo "Error: Invalid or non-multisig redeem script."
    return 1
  fi
  REQSIGS=$(echo "$SCRIPT_INFO" | jq -r '.reqSigs')
  P2SH_CHECK=$(echo "$SCRIPT_INFO" | jq -r '.p2sh')
  if [ "$P2SH_CHECK" != "$P2SH_ADDRESS" ]; then
    echo "Error: Redeem script does not match P2SH address. Expected: $P2SH_CHECK"
    return 1
  fi
  echo "This is a $REQSIGS-of-N multisig. $REQSIGS signatures required."

  # Check if private key is empty
  if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: No private key provided."
    return 1
  fi

  # Sign the transaction
  echo "Signing with private key (partial signature)..."
  SIGNED_TX=$($BINARY signrawtransaction "$RAW_TX" "$INPUTS" "[\"$PRIVATE_KEY\"]" 2>/dev/null)
  if [ -z "$SIGNED_TX" ]; then
    echo "Error: Failed to sign transaction. Check private key, transaction hex, or inputs."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  # Decode signed transaction to count signatures
  DECODED=$($BINARY decoderawtransaction "$SIGNED_HEX" 2>/dev/null)
  if [ -z "$DECODED" ]; then
    echo "Error: Failed to decode signed transaction."
    return 1
  fi
  # Count signatures: look for hex strings of 60-144 bytes (DER signatures)
  SIG_COUNT=$(echo "$DECODED" | jq -r '.vin[].scriptSig.asm' | tr ' ' '\n' | grep -E '^[0-9a-fA-F]{60,144}$' | wc -l)

  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed with $SIG_COUNT signatures!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Use 'Broadcast Final Transaction' to send it."
  else
    echo "Partial signature complete. $SIG_COUNT of $REQSIGS signatures provided."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Share this hex and inputs with another signer to sign with their private key:"
    echo "$BINARY signrawtransaction \"$SIGNED_HEX\" \"$INPUTS\" \"[<private key 2>]\""
    if [ "$SIG_COUNT" -lt "$REQSIGS" ]; then
      echo "Warning: Still need $(($REQSIGS - $SIG_COUNT)) more signature(s) to complete!"
    fi
  fi
}

# Function to broadcast the final transaction
broadcast_final_tx() {
  echo "=== Broadcast Final Transaction ==="
  read -p "Enter the transaction hex: " SIGNED_HEX

  # Check if hex is empty
  if [ -z "$SIGNED_HEX" ]; then
    echo "Error: No transaction hex provided."
    return 1
  fi

  # Send the transaction
  echo "Sending transaction..."
  TXID=$($BINARY sendrawtransaction "$SIGNED_HEX" 2>&1)
  if [[ "$TXID" =~ ^error ]]; then
    echo "Error: Failed to send transaction: $TXID"
    return 1
  fi

  echo "Success! Transaction ID: $TXID"
  echo "Check status with: $BINARY gettransaction \"$TXID\""
}

# Function to consolidate UTXOs and auto-sign
consolidate_utxos() {
  echo "=== Consolidate UTXOs ==="
  
  # Use default P2SH_ADDRESS if set, otherwise prompt
  if [ -n "$P2SH_ADDRESS" ]; then
    echo "Using P2SH address: $P2SH_ADDRESS"
  else
    read -p "Enter P2SH address to consolidate: " P2SH_ADDRESS
  fi
  
  # Use default REDEEM_SCRIPT if set, otherwise prompt
  if [ -n "$REDEEM_SCRIPT" ]; then
    echo "Using redeem script: $REDEEM_SCRIPT"
  else
    read -p "Enter redeem script: " REDEEM_SCRIPT
  fi
  
  # Use default PRIVATE_KEY if set, otherwise prompt
  if [ -n "$PRIVATE_KEY" ]; then
    echo "Using private key: $PRIVATE_KEY"
  else
    read -p "Enter your private key: " PRIVATE_KEY
  fi

  # Validate P2SH address
  if ! validate_p2sh_address "$P2SH_ADDRESS"; then
    return 1
  fi

  # Validate redeem script
  SCRIPT_INFO=$($BINARY decodescript "$REDEEM_SCRIPT" 2>/dev/null)
  if [ -z "$SCRIPT_INFO" ] || [ "$(echo "$SCRIPT_INFO" | jq -r '.type')" != "multisig" ]; then
    echo "Error: Invalid or non-multisig redeem script."
    return 1
  fi
  REQSIGS=$(echo "$SCRIPT_INFO" | jq -r '.reqSigs')
  P2SH_CHECK=$(echo "$SCRIPT_INFO" | jq -r '.p2sh')
  if [ "$P2SH_CHECK" != "$P2SH_ADDRESS" ]; then
    echo "Error: Redeem script does not match P2SH address. Expected: $P2SH_CHECK"
    return 1
  fi
  echo "Redeem script is $REQSIGS-of-N multisig. $REQSIGS signatures required."

  # Check if private key is empty
  if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: No private key provided."
    return 1
  fi

  # Step 1: Check balance and get UTXOs, sorted by amount (largest first)
  echo "Checking unspent transactions for $P2SH_ADDRESS..."
  UTXOS=$($BINARY listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]" 2>/dev/null | jq 'sort_by(-.amount)')
  if [ -z "$UTXOS" ] || [ "$UTXOS" == "[]" ]; then
    echo "Error: No unspent transactions found for $P2SH_ADDRESS."
    return 1
  fi

  # Calculate total available amount from all UTXOs
  TOTAL_AMOUNT=$(echo "$UTXOS" | jq -r '.[] | .amount' | awk '{s+=$1} END {print s}')
  if [ -z "$TOTAL_AMOUNT" ]; then
    echo "Error: Unable to calculate total balance."
    return 1
  fi
  echo "Total available balance: $TOTAL_AMOUNT"

  # Count UTXOs
  UTXO_COUNT=$(echo "$UTXOS" | jq -r 'length')
  if [ "$UTXO_COUNT" -le 1 ]; then
    echo "Error: Only $UTXO_COUNT UTXO found. Need at least 2 to consolidate."
    return 1
  fi
  echo "Number of UTXOs to consolidate: $UTXO_COUNT"

  # Step 2: Estimate fee (assuming 6 confirmations target)
  FEE_RATE=$($BINARY estimatefee 6 2>/dev/null)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0001"
    FEE_RATE=0.0001
  fi

  # Initial fee calculation (assume 250 bytes base, +100 bytes per extra input)
  TX_SIZE=$((250 + 100 * (UTXO_COUNT - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)

  # Calculate amount to send (total minus fee)
  AMOUNT_TO_SEND=$(echo "$TOTAL_AMOUNT - $FEE" | bc -l)
  if (( $(echo "$AMOUNT_TO_SEND <= 0" | bc -l) )); then
    echo "Error: Insufficient funds for consolidation after fee. Available: $TOTAL_AMOUNT, Fee: $FEE"
    return 1
  fi
  echo "Amount to consolidate (after fee): $AMOUNT_TO_SEND"

  # Step 3: Collect all UTXOs, prioritizing largest values
  echo "Collecting all UTXOs (largest first)..."
  INPUTS=""
  INPUT_JSON="["
  SELECTED_AMOUNT=0
  SELECTED_COUNT=0

  for i in $(seq 0 $((UTXO_COUNT - 1))); do
    TXID=$(echo "$UTXOS" | jq -r ".[$i].txid")
    VOUT=$(echo "$UTXOS" | jq -r ".[$i].vout")
    SCRIPT_PUBKEY=$(echo "$UTXOS" | jq -r ".[$i].scriptPubKey")
    UTXO_AMOUNT=$(echo "$UTXOS" | jq -r ".[$i].amount")

    # Add to inputs for createrawtransaction
    if [ -z "$INPUT_JSON" ]; then
      INPUT_JSON="[{\"txid\":\"$TXID\", \"vout\":$VOUT}"
    else
      INPUT_JSON="$INPUT_JSON,{\"txid\":\"$TXID\", \"vout\":$VOUT}"
    fi

    # Store for signing
    if [ -z "$INPUTS" ]; then
      INPUTS="{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    else
      INPUTS="$INPUTS,{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    fi

    # Track selected amount and count
    SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
  done
  INPUT_JSON="$INPUT_JSON]"

  # Recalculate fee based on actual number of inputs
  TX_SIZE=$((250 + 100 * (SELECTED_COUNT - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)
  AMOUNT_TO_SEND=$(echo "$SELECTED_AMOUNT - $FEE" | bc -l)
  if (( $(echo "$AMOUNT_TO_SEND <= 0" | bc -l) )); then
    echo "Error: Insufficient funds for consolidation after fee. Selected: $SELECTED_AMOUNT, Fee: $FEE"
    return 1
  fi

  # Step 4: Create raw transaction
  echo "Creating raw consolidation transaction with $SELECTED_COUNT UTXOs..."
  RAW_TX=$($BINARY createrawtransaction "$INPUT_JSON" "{\"$P2SH_ADDRESS\":$AMOUNT_TO_SEND}" 2>/dev/null)
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction. Check inputs or $BINARY."
    return 1
  fi

  # Step 5: Auto-sign with provided private key
  echo "Signing with private key (partial signature)..."
  SIGNED_TX=$($BINARY signrawtransaction "$RAW_TX" "[${INPUTS}]" "[\"$PRIVATE_KEY\"]" 2>/dev/null)
  if [ -z "$SIGNED_TX" ]; then
    echo "Error: Failed to sign transaction. Check private key, transaction hex, or inputs."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  # Decode signed transaction to count signatures
  DECODED=$($BINARY decoderawtransaction "$SIGNED_HEX" 2>/dev/null)
  if [ -z "$DECODED" ]; then
    echo "Error: Failed to decode signed transaction."
    return 1
  fi
  # Count signatures: look for hex strings of 60-144 bytes (DER signatures)
  SIG_COUNT=$(echo "$DECODED" | jq -r '.vin[].scriptSig.asm' | tr ' ' '\n' | grep -E '^[0-9a-fA-F]{60,144}$' | wc -l)

  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed with $SIG_COUNT signatures!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Proceed to broadcast with: $BINARY sendrawtransaction \"$SIGNED_HEX\""
  else
    echo "Partial signature complete. $SIG_COUNT of $REQSIGS signatures provided."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Inputs for signing: [$INPUTS]"
    echo "Share this hex and inputs with another signer to sign with their private key:"
    echo "$BINARY signrawtransaction \"$SIGNED_HEX\" \"[$INPUTS]\" \"[<private key 2>]\""
    echo "After getting the fully signed hex, broadcast with:"
    echo "$BINARY sendrawtransaction <fully signed hex>"
    if [ "$SIG_COUNT" -lt "$REQSIGS" ]; then
      echo "Warning: Still need $(($REQSIGS - $SIG_COUNT)) more signature(s) to complete!"
    fi
  fi
}

# Main menu
while true; do
  # Update balance and UTXO count
  read_balance_utxos
  echo "=== Multisig P2SH Transaction Status ==="
  echo "P2SH Address: $P2SH_ADDRESS"
  echo "Balance: $TOTAL_AMOUNT"
  echo "Available UTXOs: $UTXO_COUNT"
  echo "=== Multisig P2SH Transaction Menu ==="
  echo "1. Create Send Transaction"
  echo "2. Sign Partial Transaction"
  echo "3. Broadcast Final Transaction"
  echo "4. Consolidate UTXOs"
  echo "5. Exit"
  read -p "Select an option (1-5): " OPTION

  case $OPTION in
    1)
      create_send_transaction
      ;;
    2)
      sign_partial_tx
      ;;
    3)
      broadcast_final_tx
      ;;
    4)
      consolidate_utxos
      ;;
    5)
      echo "Exiting..."
      rm -f /tmp/balance_utxo_status
      exit 0
      ;;
    *)
      echo "Invalid option. Please select 1, 2, 3, 4, or 5."
      ;;
  esac
  echo
done
