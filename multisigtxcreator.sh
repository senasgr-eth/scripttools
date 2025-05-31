#!/bin/bash
# Bash script with menu for creating, signing, broadcasting multisig P2SH transactions, and consolidating UTXOs using junkcoin-cli
# Handles multiple UTXOs for sufficient funds with enhanced error checking

# Function to create a raw transaction
create_send_transaction() {
  echo "=== Create Send Transaction ==="
  read -p "Enter P2SH address: " P2SH_ADDRESS
  read -p "Enter redeem script: " REDEEM_SCRIPT
  read -p "Enter amount to send: " AMOUNT_TO_SEND
  read -p "Enter destination address: " DESTINATION_ADDRESS

  # Validate P2SH address
  VALIDATE=$(./junkcoin-cli validateaddress "$P2SH_ADDRESS")
  IS_VALID=$(echo "$VALIDATE" | jq -r '.isvalid')
  if [ "$IS_VALID" != "true" ]; then
    echo "Error: Invalid P2SH address."
    return 1
  fi

  # Step 1: Check balance and get UTXOs
  echo "Checking unspent transactions for $P2SH_ADDRESS..."
  UTXOS=$(./junkcoin-cli listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]")
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
  FEE_RATE=$(./junkcoin-cli estimatefee 6)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0001 JUNK"
    FEE_RATE=0.0001
  fi

  # Rough fee calculation (assume 250 bytes base, +100 bytes per extra input)
  UTXO_COUNT=$(echo "$UTXOS" | jq -r 'length')
  TX_SIZE=$((250 + 100 * (UTXO_COUNT - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)

  # Check if total amount is sufficient
  TOTAL_NEEDED=$(echo "$AMOUNT_TO_SEND + $FEE" | bc -l)
  if (( $(echo "$TOTAL_AMOUNT < $TOTAL_NEEDED" | bc -l) )); then
    echo "Error: Insufficient funds. Available: $TOTAL_AMOUNT, Requested: $AMOUNT_TO_SEND, Fee: $FEE"
    return 1
  fi

  # Step 3: Collect enough UTXOs to cover amount + fee
  echo "Selecting UTXOs to cover $TOTAL_NEEDED..."
  INPUTS=""
  SELECTED_AMOUNT=0
  INPUT_JSON="["

  for i in $(seq 0 $((UTXO_COUNT - 1))); do
    UTXO_AMOUNT=$(echo "$UTXOS" | jq -r ".[$i].amount")
    TXID=$(echo "$UTXOS" | jq -r ".[$i].txid")
    VOUT=$(echo "$UTXOS" | jq -r ".[$i].vout")
    SCRIPT_PUBKEY=$(echo "$UTXOS" | jq -r ".[$i].scriptPubKey")

    # Add this UTXO to inputs
    SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)
    if [ -z "$INPUTS" ]; then
      INPUT_JSON="[{\"txid\":\"$TXID\", \"vout\":$VOUT}"
      INPUTS="{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    else
      INPUT_JSON="$INPUT_JSON,{\"txid\":\"$TXID\", \"vout\":$VOUT}"
      INPUTS="$INPUTS,{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    fi

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
  echo "Creating raw transaction..."
  RAW_TX=$(./junkcoin-cli createrawtransaction "$INPUT_JSON" "{\"$DESTINATION_ADDRESS\":$AMOUNT_TO_SEND, \"$P2SH_ADDRESS\":$CHANGE}")
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction."
    return 1
  fi

  echo "Raw transaction created! Hex: $RAW_TX"
  echo "Inputs for signing: [$INPUTS]"
  echo "Save this hex and inputs for signing. You can use 'Sign Partial Transaction' next."
}

# Function to sign a partial transaction
sign_partial_tx() {
  echo "=== Sign Partial Transaction ==="
  read -p "Enter P2SH address: " P2SH_ADDRESS
  read -p "Enter redeem script: " REDEEM_SCRIPT
  read -p "Enter the raw or partially signed transaction hex: " RAW_TX
  read -p "Enter the inputs JSON (from create step, e.g., [{\"txid\":..., \"vout\":...}]): " INPUTS
  read -s -p "Enter your private key: " PRIVATE_KEY
  echo

  # Validate P2SH address
  VALIDATE=$(./junkcoin-cli validateaddress "$P2SH_ADDRESS")
  IS_VALID=$(echo "$VALIDATE" | jq -r '.isvalid')
  if [ "$IS_VALID" != "true" ]; then
    echo "Error: Invalid P2SH address."
    return 1
  fi

  # Sign the transaction
  echo "Signing with private key (partial signature)..."
  SIGNED_TX=$(./junkcoin-cli signrawtransaction "$RAW_TX" "$INPUTS" "[\"$PRIVATE_KEY\"]")
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Use 'Broadcast Final Transaction' to send it."
  else
    echo "Partial signature complete. You need another signature for multisig."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Share this hex with another signer to sign with their private key:"
    echo "./junkcoin-cli signrawtransaction \"$SIGNED_HEX\" \"$INPUTS\" \"[<private key 2>]\""
  fi
}

# Function to broadcast the final transaction
broadcast_final_tx() {
  echo "=== Broadcast Final Transaction ==="
  read -p "Enter the fully signed transaction hex: " SIGNED_HEX

  # Send the transaction
  echo "Sending transaction..."
  TXID=$(./junkcoin-cli sendrawtransaction "$SIGNED_HEX")
  if [ -z "$TXID" ]; then
    echo "Error: Failed to send transaction."
    return 1
  fi

  echo "Success! Transaction ID: $TXID"
  echo "Check status with: ./junkcoin-cli gettransaction \"$TXID\""
}

# Function to consolidate UTXOs
consolidate_utxos() {
  echo "=== Consolidate UTXOs ==="
  read -p "Enter P2SH address to consolidate: " P2SH_ADDRESS
  read -p "Enter redeem script: " REDEEM_SCRIPT
  read -s -p "Enter your private key (for partial signing): " PRIVATE_KEY
  echo

  # Validate P2SH address
  VALIDATE=$(./junkcoin-cli validateaddress "$P2SH_ADDRESS")
  IS_VALID=$(echo "$VALIDATE" | jq -r '.isvalid')
  if [ "$IS_VALID" != "true" ]; then
    echo "Error: Invalid P2SH address."
    return 1
  fi

  # Step 1: Check balance and get UTXOs
  echo "Checking unspent transactions for $P2SH_ADDRESS..."
  UTXOS=$(./junkcoin-cli listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]")
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
  FEE_RATE=$(./junkcoin-cli estimatefee 6)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0001 JUNK"
    FEE_RATE=0.0001
  fi

  # Rough fee calculation (assume 250 bytes base, +100 bytes per extra input)
  TX_SIZE=$((250 + 100 * (UTXO_COUNT - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)

  # Calculate amount to send (total minus fee)
  AMOUNT_TO_SEND=$(echo "$TOTAL_AMOUNT - $FEE" | bc -l)
  if (( $(echo "$AMOUNT_TO_SEND <= 0" | bc -l) )); then
    echo "Error: Insufficient funds for consolidation after fee. Available: $TOTAL_AMOUNT, Fee: $FEE"
    return 1
  fi
  echo "Amount to consolidate (after fee): $AMOUNT_TO_SEND"

  # Step 3: Collect all UTXOs
  echo "Collecting all UTXOs..."
  INPUTS=""
  INPUT_JSON="["

  for i in $(seq 0 $((UTXO_COUNT - 1))); do
    TXID=$(echo "$UTXOS" | jq -r ".[$i].txid")
    VOUT=$(echo "$UTXOS" | jq -r ".[$i].vout")
    SCRIPT_PUBKEY=$(echo "$UTXOS" | jq -r ".[$i].scriptPubKey")

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
  done
  INPUT_JSON="$INPUT_JSON]"

  # Step 4: Create raw transaction
  echo "Creating raw consolidation transaction..."
  RAW_TX=$(./junkcoin-cli createrawtransaction "$INPUT_JSON" "{\"$P2SH_ADDRESS\":$AMOUNT_TO_SEND}")
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction."
    return 1
  fi

  # Step 5: Sign raw transaction with private key (partial for multisig)
  echo "Signing with private key (partial signature)..."
  SIGNED_TX=$(./junkcoin-cli signrawtransaction "$RAW_TX" "[${INPUTS}]" "[\"$PRIVATE_KEY\"]")
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Proceed to broadcast with: ./junkcoin-cli sendrawtransaction \"$SIGNED_HEX\""
  else
    echo "Partial signature complete. You need another signature for multisig."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Inputs for signing: [$INPUTS]"
    echo "Share this hex and inputs with another signer to sign with their private key:"
    echo "./junkcoin-cli signrawtransaction \"$SIGNED_HEX\" \"[$INPUTS]\" \"[<private key 2>]\""
    echo "After getting the fully signed hex, broadcast with:"
    echo "./junkcoin-cli sendrawtransaction <fully signed hex>"
  fi
}

# Main menu
while true; do
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
      exit 0
      ;;
    *)
      echo "Invalid option. Please select 1, 2, 3, 4, or 5."
      ;;
  esac
  echo
done
