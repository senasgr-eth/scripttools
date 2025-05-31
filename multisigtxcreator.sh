#!/bin/bash
# Bash script with menu for creating, signing, broadcasting multisig P2SH transactions, and consolidating large numbers of UTXOs using junkcoin-cli
# Saves signed hex and inputs to JSON file with format <first_4_letters>_<utxo_count>_step<step_number>_<timestamp>.json
# Supports JSON file input for signing (option 2) and broadcasting (option 3)
# Uses temporary file for inputs to fix Argument list too long error
# Selects UTXOs by largest amount first in consolidate_utxos and create_send_transaction

# Configurable UTXO limit per consolidation transaction
DEFAULT_UTXO_LIMIT=500

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
  TOTAL_AMOUNT=$(echo "$UTXOS" | jq -r '[.[] | .amount] | add // 0')
  if [ -z "$TOTAL_AMOUNT" ] || [ "$TOTAL_AMOUNT" == "0" ]; then
    echo "Error: Unable to calculate total balance."
    return 1
  fi
  echo "Total available balance: $TOTAL_AMOUNT"

  # Step 2: Estimate fee (assuming 6 confirmations target)
  FEE_RATE=$(./junkcoin-cli estimatefee 6)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0001 JKC"
    FEE_RATE=0.0001
  fi

  # Step 3: Collect enough UTXOs to cover amount + fee, sorted by amount descending
  echo "Selecting largest UTXOs to cover $AMOUNT_TO_SEND plus fee..."
  INPUTS=""
  INPUT_JSON="["
  SELECTED_AMOUNT=0
  SELECTED_UTXO_COUNT=0

  # Extract UTXO data in a single jq call, sorted by amount descending
  UTXO_DATA=$(echo "$UTXOS" | jq -r "sort_by(-.amount) | .[] | [.amount, .txid, .vout, .scriptPubKey] | @tsv")
  if [ -z "$UTXO_DATA" ]; then
    echo "Error: Failed to extract UTXO data."
    return 1
  fi

  # Process each UTXO until enough is selected
  while IFS=$'\t' read -r UTXO_AMOUNT TXID VOUT SCRIPT_PUBKEY; do
    # Add to inputs for createrawtransaction
    SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)
    if [ "$SELECTED_UTXO_COUNT" -eq 0 ]; then
      INPUT_JSON="[{\"txid\":\"$TXID\",\"vout\":$VOUT}"
    else
      INPUT_JSON="$INPUT_JSON,{\"txid\":\"$TXID\",\"vout\":$VOUT}"
    fi

    # Store for signing
    if [ -z "$INPUTS" ]; then
      INPUTS="{\"txid\":\"$TXID\",\"vout\":$VOUT,\"scriptPubKey\":\"$SCRIPT_PUBKEY\",\"redeemScript\":\"$REDEEM_SCRIPT\"}"
    else
      INPUTS="$INPUTS,{\"txid\":\"$TXID\",\"vout\":$VOUT,\"scriptPubKey\":\"$SCRIPT_PUBKEY\",\"redeemScript\":\"$REDEEM_SCRIPT\"}"
    fi

    SELECTED_UTXO_COUNT=$((SELECTED_UTXO_COUNT + 1))

    # Estimate fee based on current inputs (250 bytes base + 100 bytes per input)
    TX_SIZE=$((250 + 100 * SELECTED_UTXO_COUNT))
    FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)
    TOTAL_NEEDED=$(echo "$AMOUNT_TO_SEND + $FEE" | bc -l)

    # Check if we have enough
    if (( $(echo "$SELECTED_AMOUNT >= $TOTAL_NEEDED" | bc -l) )); then
      break
    fi

    # Progress indicator
    if [ $((SELECTED_UTXO_COUNT % 10)) -eq 0 ]; then
      echo "Selected $SELECTED_UTXO_COUNT UTXOs, total $SELECTED_AMOUNT JKC..."
    fi
  done <<< "$UTXO_DATA"
  INPUT_JSON="$INPUT_JSON]"

  # Check if sufficient funds were selected
  if (( $(echo "$SELECTED_AMOUNT < $TOTAL_NEEDED" | bc -l) )); then
    echo "Error: Insufficient funds. Selected: $SELECTED_AMOUNT, Needed: $TOTAL_NEEDED"
    return 1
  fi

  # Verify JSON syntax
  echo "Input JSON: $INPUT_JSON"
  if ! echo "$INPUT_JSON" | jq . > /dev/null 2>&1; then
    echo "Error: Invalid JSON for createrawtransaction inputs."
    return 1
  fi

  # Calculate change
  CHANGE=$(echo "$SELECTED_AMOUNT - $AMOUNT_TO_SEND - $FEE" | bc -l)
  if (( $(echo "$CHANGE < 0" | bc -l) )); then
    echo "Error: Insufficient funds selected for amount + fee. Selected: $SELECTED_AMOUNT, Requested: $AMOUNT_TO_SEND, Fee: $FEE"
    return 1
  fi

  # Step 4: Create raw transaction
  echo "Creating raw transaction with $SELECTED_UTXO_COUNT inputs..."
  RAW_TX=$(./junkcoin-cli createrawtransaction "$INPUT_JSON" "{\"$DESTINATION_ADDRESS\":$AMOUNT_TO_SEND,\"$P2SH_ADDRESS\":$CHANGE}")
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction."
    return 1
  fi

  echo "Raw transaction created! Hex: $RAW_TX"
  echo "Inputs for signing: [$INPUTS]"

  # Save to JSON file (send<TIMESTAMP>.json)
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  OUTPUT_FILE="send_${TIMESTAMP}.json"
  cat << EOF > "$OUTPUT_FILE"
{
  "signed_hex": "$RAW_TX",
  "inputs_json": [$INPUTS]
}
EOF
  if [ $? -eq 0 ]; then
    echo "Saved raw transaction hex and inputs to $OUTPUT_FILE"
  else
    echo "Error: Failed to save to $OUTPUT_FILE"
    return 1
  fi
  echo "You can use this file for signing (option 2) or broadcasting (option 3) as needed."
}

# Function to sign a partial transaction
sign_partial_tx() {
  echo "=== Sign Partial Transaction ==="
  read -p "Enter JSON file path (e.g., 3P3U_500_step1_20250531123600.json) or press Enter for manual input: " JSON_FILE
  if [ -n "$JSON_FILE" ]; then
    # Validate JSON file
    if [ ! -f "$JSON_FILE" ]; then
      echo "Error: JSON file $JSON_FILE does not exist."
      return 1
    fi
    # Extract signed_hex and inputs_json
    RAW_TX=$(jq -r '.signed_hex' "$JSON_FILE")
    INPUTS=$(jq -r '.inputs_json' "$JSON_FILE")
    if [ -z "$RAW_TX" ] || [ "$RAW_TX" == "null" ] || [ -z "$INPUTS" ] || [ "$INPUTS" == "null" ]; then
      echo "Error: Invalid JSON file. Missing signed_hex or inputs_json."
      return 1
    fi
    echo "Loaded signed_hex and inputs_json from $JSON_FILE"
  else
    read -p "Enter P2SH address: " P2SH_ADDRESS
    read -p "Enter redeem script: " REDEEM_SCRIPT
    read -p "Enter the raw or partially signed transaction hex: " RAW_TX
    read -p "Enter the inputs JSON (from create step, e.g., [{\"txid\":..., \"vout\":...}]): " INPUTS
  fi

  read -s -p "Enter your private key: " PRIVATE_KEY
  echo

  # Validate P2SH address if provided
  if [ -n "$P2SH_ADDRESS" ]; then
    VALIDATE=$(./junkcoin-cli validateaddress "$P2SH_ADDRESS")
    IS_VALID=$(echo "$VALIDATE" | jq -r '.isvalid')
    if [ "$IS_VALID" != "true" ]; then
      echo "Error: Invalid P2SH address."
      return 1
    fi
  fi

  # Sign the transaction
  echo "Signing with private key (partial signature)..."
  # Write INPUTS to a temporary file to avoid argument list too long
  TEMP_INPUTS=$(mktemp)
  echo "$INPUTS" > "$TEMP_INPUTS"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to write inputs to temporary file."
    rm -f "$TEMP_INPUTS"
    return 1
  fi
  SIGNED_TX=$(./junkcoin-cli signrawtransaction "$RAW_TX" "$(cat "$TEMP_INPUTS")" "[\"$PRIVATE_KEY\"]")
  SIGN_RESULT=$?
  rm -f "$TEMP_INPUTS"
  if [ $SIGN_RESULT -ne 0 ]; then
    echo "Error: Failed to sign transaction."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Use 'Broadcast Final Transaction' to send it."
  else
    echo "Partial signature complete."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Share this hex with inputs for further signing:"
    echo "./junkcoin-cli signrawtransaction \"$SIGNED_HEX\" \"$INPUTS\" \"[<private key>]\""
  fi
}

# Function to broadcast the final transaction
broadcast_final_tx() {
  echo "=== Broadcast Final Transaction ==="
  read -p "Enter JSON file path (e.g., 3P3U_500_step1_20250531123600.json) or press Enter for raw hex input: " JSON_FILE
  if [ -n "$JSON_FILE" ]; then
    # Validate JSON file
    if [ ! -f "$JSON_FILE" ]; then
      echo "Error: JSON file $JSON_FILE does not exist."
      return 1
    fi
    # Extract signed_hex
    SIGNED_HEX=$(jq -r '.signed_hex' "$JSON_FILE")
    if [ -z "$SIGNED_HEX" ] || [ "$SIGNED_HEX" == "null" ]; then
      echo "Error: Invalid JSON file. Missing signed_hex."
      return 1
    fi
    echo "Loaded signed_hex from $JSON_FILE"
  else
    read -p "Enter the fully signed transaction hex: " SIGNED_HEX
  fi

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
  read -p "Enter maximum UTXOs to consolidate per transaction (default $DEFAULT_UTXO_LIMIT): " USER_LIMIT
  MAX_UTXOS=${USER_LIMIT:-$DEFAULT_UTXO_LIMIT}

  # Step 1: Check balance and get UTXOs
  echo "Checking unspent transactions for $P2SH_ADDRESS..."
  UTXOS=$(./junkcoin-cli listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]")
  if [ -z "$UTXOS" ] || [ "$UTXOS" == "[]" ]; then
    echo "Error: No unspent transactions found for $P2SH_ADDRESS."
    return 1
  fi

  # Calculate total available amount from all UTXOs
  TOTAL_AMOUNT=$(echo "$UTXOS" | jq -r '[.[] | .amount] | add // 0')
  if [ -z "$TOTAL_AMOUNT" ] || [ "$TOTAL_AMOUNT" == "0" ]; then
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
  echo "Number of UTXOs available: $UTXO_COUNT"

  # Limit UTXOs to process
  UTXOS_TO_PROCESS=$(( UTXO_COUNT < MAX_UTXOS ? UTXO_COUNT : MAX_UTXOS ))
  echo "Processing $UTXOS_TO_PROCESS UTXOs in this transaction..."

  # Step 2: Estimate fee (assuming 6 confirmations target)
  FEE_RATE=$(./junkcoin-cli estimatefee 6)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0001 JKC"
    FEE_RATE=0.0001
  fi

  # Rough fee calculation (assume 250 bytes base, +100 bytes per extra input)
  TX_SIZE=$((250 + 100 * ($UTXOS_TO_PROCESS - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)

  # Step 3: Collect UTXOs for this transaction, sorted by amount descending
  echo "Collecting $UTXOS_TO_PROCESS UTXOs (largest amounts first)..."
  INPUTS=""
  INPUT_JSON="["
  SELECTED_AMOUNT=0

  # Extract UTXO data in a single jq call, sorted by amount descending
  UTXO_DATA=$(echo "$UTXOS" | jq -r "sort_by(-.amount) | .[:$UTXOS_TO_PROCESS] | .[] | [.amount, .txid, .vout, .scriptPubKey] | @tsv")
  if [ -z "$UTXO_DATA" ]; then
    echo "Error: Failed to extract UTXO data."
    return 1
  fi

  # Process each UTXO
  i=0
  while IFS=$'\t' read -r UTXO_AMOUNT TXID VOUT SCRIPT_PUBKEY; do
    # Add to inputs for createrawtransaction
    if [ "$i" -eq 0 ]; then
      INPUT_JSON="[{\"txid\":\"$TXID\",\"vout\":$VOUT}"
    else
      INPUT_JSON="$INPUT_JSON,{\"txid\":\"$TXID\",\"vout\":$VOUT}"
    fi

    # Store for signing
    if [ -z "$INPUTS" ]; then
      INPUTS="{\"txid\":\"$TXID\",\"vout\":$VOUT,\"scriptPubKey\":\"$SCRIPT_PUBKEY\",\"redeemScript\":\"$REDEEM_SCRIPT\"}"
    else
      INPUTS="$INPUTS,{\"txid\":\"$TXID\",\"vout\":$VOUT,\"scriptPubKey\":\"$SCRIPT_PUBKEY\",\"redeemScript\":\"$REDEEM_SCRIPT\"}"
    fi

    # Update selected amount
    SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)

    # Progress indicator
    if [ $((i % 10)) -eq 0 ]; then
      echo "Collected $i/$UTXOS_TO_PROCESS UTXOs..."
    fi

    i=$((i + 1))
  done <<< "$UTXO_DATA"
  INPUT_JSON="$INPUT_JSON]"

  # Verify JSON syntax
  echo "Input JSON: $INPUT_JSON"
  if ! echo "$INPUT_JSON" | jq . > /dev/null 2>&1; then
    echo "Error: Invalid JSON for createrawtransaction inputs."
    return 1
  fi

  # Calculate amount to send (selected amount minus fee)
  AMOUNT_TO_SEND=$(echo "$SELECTED_AMOUNT - $FEE" | bc -l)
  if (( $(echo "$AMOUNT_TO_SEND <= 0" | bc -l) )); then
    echo "Error: Insufficient funds for consolidation after fee. Selected: $SELECTED_AMOUNT, Fee: $FEE"
    return 1
  fi
  echo "Amount to consolidate (after fee): $AMOUNT_TO_SEND"

  # Step 4: Create raw transaction
  echo "Creating raw consolidation transaction..."
  RAW_TX=$(./junkcoin-cli createrawtransaction "$INPUT_JSON" "{\"$P2SH_ADDRESS\":$AMOUNT_TO_SEND}")
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction."
    return 1
  fi

  # Step 5: Sign raw transaction with private key (partial for multisig)
  echo "Signing with private key (partial signature)..."
  # Write INPUTS to a temporary file to avoid argument list too long
  TEMP_INPUTS=$(mktemp)
  echo "[${INPUTS}]" > "$TEMP_INPUTS"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to write inputs to temporary file."
    rm -f "$TEMP_INPUTS"
    return 1
  fi
  SIGNED_TX=$(./junkcoin-cli signrawtransaction "$RAW_TX" "$(cat "$TEMP_INPUTS")" "[\"$PRIVATE_KEY\"]")
  SIGN_RESULT=$?
  rm -f "$TEMP_INPUTS"
  if [ $SIGN_RESULT -ne 0 ]; then
    echo "Error: Failed to sign transaction."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

  # Step 6: Save signed hex and inputs to JSON file with step and timestamp
  WALLET_PREFIX=$(echo "$P2SH_ADDRESS" | cut -c1-4)
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  # Determine step number by counting existing files
  STEP_NUMBER=1
  while [ -f "${WALLET_PREFIX}_${UTXOS_TO_PROCESS}_step${STEP_NUMBER}_${TIMESTAMP}.json" ]; do
    STEP_NUMBER=$((STEP_NUMBER + 1))
  done
  OUTPUT_FILE="${WALLET_PREFIX}_${UTXOS_TO_PROCESS}_step${STEP_NUMBER}_${TIMESTAMP}.json"
  cat << EOF > "$OUTPUT_FILE"
{
  "signed_hex": "$SIGNED_HEX",
  "inputs_json": [$INPUTS]
}
EOF
  if [ $? -eq 0 ]; then
    echo "Saved signed hex and inputs to $OUTPUT_FILE"
  else
    echo "Error: Failed to save to $OUTPUT_FILE"
    return 1
  fi

  # Display signing status
  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed!"
    echo "Signed transaction hex saved in $OUTPUT_FILE"
    echo "Proceed to broadcast with option 3 (Broadcast Final Transaction)."
  else
    echo "Partial signature complete. You need another signature for multisig."
    echo "Partially signed transaction hex and inputs saved in $OUTPUT_FILE"
    echo "Use option 2 to sign with another private key, providing $OUTPUT_FILE as input."
    echo "After getting the fully signed hex, use option 3 to broadcast."
  fi

  # Estimate remaining transactions
  REMAINING_UTXOS=$((UTXO_COUNT - UTXOS_TO_PROCESS))
  if [ "$REMAINING_UTXOS" -le 1 ]; then
    echo "No more UTXOs to consolidate after this transaction."
    return 0
  fi
  ESTIMATED_TXS=$(( (REMAINING_UTXOS + MAX_UTXOS - 1) / MAX_UTXOS ))
  echo "Approximately $REMAINING_UTXOS UTXOs remain, requiring ~$ESTIMATED_TXS more transactions."
  echo "To continue, obtain the second signature, broadcast the current transaction (option 3), then run option 4 again."
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
