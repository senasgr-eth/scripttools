#!/bin/bash
# Bash script for batch processing UTXO consolidation in a multisig P2SH wallet
# Handles large numbers of UTXOs by processing in batches (default 200 UTXOs per batch)
# Creates temporary JSON files for each batch to store inputs and transaction details for signing
# Auto-signs each batch with the provided private key, saves partially signed results
# Includes error checking, fee estimation, and background balance fetching
# Fixed JSON construction for createrawtransaction to avoid parsing errors

# Default variables (set these or leave empty to prompt)
BINARY="./junkcoin-cli"
P2SH_ADDRESS="34P2otqp4hUL4kRoVH74KpyrBdkrqZM18n"
REDEEM_SCRIPT="52210242a71da46329fa5cc0f600e5589181cdacbb99a6a9cd9cc349e9d96e6a601eb02103d57967f8cbf1592c45c60ade39274494bec4ba8ee538bab5ffb3eb2d023dbbe952ae"
PRIVATE_KEY=""
BATCH_SIZE=200  # Default batch size for UTXO processing

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

# Function to consolidate UTXOs in batches
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
    echo "Using private key: [hidden]"
  else
    read -p "Enter your private key: " PRIVATE_KEY
  fi

  # Prompt for batch size, use default if empty
  read -p "Enter batch size (default $BATCH_SIZE UTXOs per batch): " INPUT_BATCH_SIZE
  if [ -n "$INPUT_BATCH_SIZE" ]; then
    BATCH_SIZE=$INPUT_BATCH_SIZE
  fi
  echo "Using batch size: $BATCH_SIZE"

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
    echo "Warning: Fee estimation failed, using default 0.0002"
    FEE_RATE=0.0002
  fi

  # Step 3: Process UTXOs in batches
  BATCH_NUM=1
  START_IDX=0
  while [ "$START_IDX" -lt "$UTXO_COUNT" ]; do
    echo "Processing batch $BATCH_NUM (UTXOs $((START_IDX + 1)) to $((START_IDX + BATCH_SIZE)))..."

    # Collect UTXOs for this batch
    INPUTS=""
    INPUT_JSON="[]"
    SELECTED_AMOUNT=0
    SELECTED_COUNT=0
    END_IDX=$((START_IDX + BATCH_SIZE - 1))
    if [ "$END_IDX" -ge "$UTXO_COUNT" ]; then
      END_IDX=$((UTXO_COUNT - 1))
    fi

    # Build INPUT_JSON using jq for proper JSON formatting
    for i in $(seq $START_IDX $END_IDX); do
      TXID=$(echo "$UTXOS" | jq -r ".[$i].txid")
      VOUT=$(echo "$UTXOS" | jq -r ".[$i].vout")
      SCRIPT_PUBKEY=$(echo "$UTXOS" | jq -r ".[$i].scriptPubKey")
      UTXO_AMOUNT=$(echo "$UTXOS" | jq -r ".[$i].amount")

      # Add to INPUT_JSON using jq for proper JSON formatting
      NEW_ENTRY=$(echo "{}" | jq -c --arg t "$TXID" --argjson v "$VOUT" '. + {"txid": $t, "vout": $v}')
      INPUT_JSON=$(echo "$INPUT_JSON" | jq -c --argjson entry "$NEW_ENTRY" '. + [$entry]')

      # Store for signing - create a proper JSON array element
      NEW_INPUT="{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
      if [ -z "$INPUTS" ]; then
        INPUTS="$NEW_INPUT"
      else
        INPUTS="$INPUTS,$NEW_INPUT"
      fi

      # Track selected amount and count
      SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)
      SELECTED_COUNT=$((SELECTED_COUNT + 1))
    done

    # Debug: Output the constructed JSON
    echo "Debug: INPUT_JSON for batch $BATCH_NUM: $INPUT_JSON"

    # Calculate fee for this batch
    TX_SIZE=$((250 + 100 * (SELECTED_COUNT - 1)))
    FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)
    AMOUNT_TO_SEND=$(echo "$SELECTED_AMOUNT - $FEE" | bc -l)
    if (( $(echo "$AMOUNT_TO_SEND <= 0" | bc -l) )); then
      echo "Error: Insufficient funds for batch $BATCH_NUM after fee. Selected: $SELECTED_AMOUNT, Fee: $FEE"
      return 1
    fi
    echo "Batch $BATCH_NUM: Selected amount: $SELECTED_AMOUNT, Fee: $FEE, Amount to consolidate: $AMOUNT_TO_SEND"

    # Prepare outputs JSON
    OUTPUTS_JSON=$(echo "{}" | jq -c --arg addr "$P2SH_ADDRESS" --argjson amt "$AMOUNT_TO_SEND" '. + {($addr): $amt}')

    # Debug: Output the command
    echo "Debug: Command: $BINARY createrawtransaction '$INPUT_JSON' '$OUTPUTS_JSON'"

    # Step 4: Create raw transaction for this batch
    echo "Creating raw consolidation transaction for batch $BATCH_NUM with $SELECTED_COUNT UTXOs..."
    RAW_TX=$($BINARY createrawtransaction "$INPUT_JSON" "$OUTPUTS_JSON" 2>&1)
    if [ -z "$RAW_TX" ] || [[ "$RAW_TX" =~ ^error ]]; then
      echo "Error: Failed to create raw transaction for batch $BATCH_NUM. Output: $RAW_TX"
      echo "Check inputs, $BINARY, or node status."
      return 1
    fi

    # Step 5: Save temporary JSON for this batch
    TEMP_JSON="temp_batch_${BATCH_NUM}_$(date +%Y%m%d_%H%M%S).json"
    echo "Saving batch $BATCH_NUM inputs to $TEMP_JSON..."
    echo "{\"p2sh_address\":\"$P2SH_ADDRESS\", \"redeem_script\":\"$REDEEM_SCRIPT\", \"inputs\":[$INPUTS], \"raw_tx\":\"$RAW_TX\"}" > "$TEMP_JSON"

    # Step 6: Auto-sign with provided private key
    echo "Signing batch $BATCH_NUM with private key (partial signature)..."
    # Properly format the inputs as a JSON array
    INPUTS_ARRAY="[$INPUTS]"
    echo "Debug: Using inputs array: $INPUTS_ARRAY"
    SIGNED_TX=$($BINARY signrawtransaction "$RAW_TX" "$INPUTS_ARRAY" "[\"$PRIVATE_KEY\"]" 2>/dev/null)
    if [ -z "$SIGNED_TX" ]; then
      echo "Error: Failed to sign batch $BATCH_NUM. Check private key, transaction hex, or inputs."
      return 1
    fi
    COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
    SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')

    # Decode signed transaction to count signatures
    DECODED=$($BINARY decoderawtransaction "$SIGNED_HEX" 2>/dev/null)
    if [ -z "$DECODED" ]; then
      echo "Error: Failed to decode signed transaction for batch $BATCH_NUM."
      return 1
    fi
    # Count signatures in all inputs
  SIG_COUNT=0
  VIN_COUNT=$(echo "$DECODED" | jq -r '.vin | length')
  for i in $(seq 0 $((VIN_COUNT - 1))); do
    INPUT_SIGS=$(echo "$DECODED" | jq -r ".vin[$i].scriptSig.asm" | tr ' ' '\n' | grep -E '^[0-9a-fA-F]{60,144}$' | wc -l)
    SIG_COUNT=$((SIG_COUNT + INPUT_SIGS))
  done

    # Step 7: Save signed batch to JSON file
    JSON_FILE="tx_consolidate_batch_${BATCH_NUM}_$(date +%Y%m%d_%H%M%S).json"
    echo "Saving batch $BATCH_NUM transaction details to $JSON_FILE..."
    echo "{\"p2sh_address\":\"$P2SH_ADDRESS\", \"redeem_script\":\"$REDEEM_SCRIPT\", \"inputs\":[$INPUTS], \"signed_hex\":\"$SIGNED_HEX\", \"complete\":$COMPLETE, \"signatures\":$SIG_COUNT, \"required_signatures\":$REQSIGS}" > "$JSON_FILE"

    if [ "$COMPLETE" == "true" ]; then
      echo "Batch $BATCH_NUM fully signed with $SIG_COUNT signatures!"
      echo "Signed transaction hex: $SIGNED_HEX"
      echo "Transaction details saved to: $JSON_FILE"
      echo "Proceed to broadcast with 'Broadcast Final Transaction' using this file or hex."
    else
      echo "Batch $BATCH_NUM: Partial signature complete. $SIG_COUNT of $REQSIGS signatures provided."
      echo "Partially signed transaction hex: $SIGNED_HEX"
      echo "Transaction details saved to: $JSON_FILE"
      echo "Share $JSON_FILE or the following with another signer:"
      echo "Hex: $SIGNED_HEX"
      echo "Inputs for signing: [$INPUTS]"
      echo "Command: $BINARY signrawtransaction \"$SIGNED_HEX\" \"$INPUTS\" \"[<private key 2>]\""
      echo "After getting the fully signed hex, broadcast with 'Broadcast Final Transaction'."
      if [ "$SIG_COUNT" -lt "$REQSIGS" ]; then
        echo "Warning: Still need $(($REQSIGS - $SIG_COUNT)) more signature(s) to complete batch $BATCH_NUM!"
      fi
    fi

    # Move to next batch
    START_IDX=$((START_IDX + BATCH_SIZE))
    BATCH_NUM=$((BATCH_NUM + 1))
    echo
  done
}

# Function to create a raw transaction and auto-sign
create_send_transaction() {
  echo "=== Create Send Transaction ==="
  if [ -n "$P2SH_ADDRESS" ]; then
    echo "Using P2SH address: $P2SH_ADDRESS"
  else
    read -p "Enter P2SH address: " P2SH_ADDRESS
  fi
  if [ -n "$REDEEM_SCRIPT" ]; then
    echo "Using redeem script: $REDEEM_SCRIPT"
  else
    read -p "Enter redeem script: " REDEEM_SCRIPT
  fi
  read -p "Enter amount to send: " AMOUNT_TO_SEND
  read -p "Enter destination address: " DESTINATION_ADDRESS
  if [ -n "$PRIVATE_KEY" ]; then
    echo "Using private key: [hidden]"
  else
    read -p "Enter your private key: " PRIVATE_KEY
  fi
  if ! validate_p2sh_address "$P2SH_ADDRESS"; then
    return 1
  fi
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
  if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: No private key provided."
    return 1
  fi
  echo "Checking unspent transactions for $P2SH_ADDRESS..."
  UTXOS=$($BINARY listunspent 1 9999999 "[\"$P2SH_ADDRESS\"]" 2>/dev/null | jq 'sort_by(-.amount)')
  if [ -z "$UTXOS" ] || [ "$UTXOS" == "[]" ]; then
    echo "Error: No unspent transactions found for $P2SH_ADDRESS."
    return 1
  fi
  TOTAL_AMOUNT=$(echo "$UTXOS" | jq -r '.[] | .amount' | awk '{s+=$1} END {print s}')
  if [ -z "$TOTAL_AMOUNT" ]; then
    echo "Error: Unable to calculate total balance."
    return 1
  fi
  echo "Total available balance: $TOTAL_AMOUNT"
  FEE_RATE=$($BINARY estimatefee 6 2>/dev/null)
  if [ -z "$FEE_RATE" ] || [ "$FEE_RATE" == "-1" ]; then
    echo "Warning: Fee estimation failed, using default 0.0002"
    FEE_RATE=0.0002
  fi
  UTXO_COUNT=$(echo "$UTXOS" | jq -r 'length')
  TX_SIZE=$((250 + 100 * (UTXO_COUNT - 1)))
  FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)
  TOTAL_NEEDED=$(echo "$AMOUNT_TO_SEND + $FEE" | bc -l)
  if (( $(echo "$TOTAL_AMOUNT < $TOTAL_NEEDED" | bc -l) )); then
    echo "Error: Insufficient funds. Available: $TOTAL_AMOUNT, Requested: $AMOUNT_TO_SEND, Fee: $FEE"
    return 1
  fi
  echo "Selecting UTXOs (largest first) to cover $TOTAL_NEEDED..."
  INPUTS=""
  SELECTED_AMOUNT=0
  INPUT_JSON="[]"
  SELECTED_COUNT=0
  for i in $(seq 0 $((UTXO_COUNT - 1))); do
    UTXO_AMOUNT=$(echo "$UTXOS" | jq -r ".[$i].amount")
    TXID=$(echo "$UTXOS" | jq -r ".[$i].txid")
    VOUT=$(echo "$UTXOS" | jq -r ".[$i].vout")
    SCRIPT_PUBKEY=$(echo "$UTXOS" | jq -r ".[$i].scriptPubKey")
    SELECTED_AMOUNT=$(echo "$SELECTED_AMOUNT + $UTXO_AMOUNT" | bc -l)
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
    NEW_ENTRY=$(echo "{}" | jq -c --arg t "$TXID" --argjson v "$VOUT" '. + {"txid": $t, "vout": $v}')
    INPUT_JSON=$(echo "$INPUT_JSON" | jq -c --argjson entry "$NEW_ENTRY" '. + [$entry]')
    # Create a proper JSON object for each input
    NEW_INPUT="{\"txid\":\"$TXID\", \"vout\":$VOUT, \"scriptPubKey\":\"$SCRIPT_PUBKEY\", \"redeemScript\":\"$REDEEM_SCRIPT\"}"
    if [ -z "$INPUTS" ]; then
      INPUTS="$NEW_INPUT"
    else
      INPUTS="$INPUTS,$NEW_INPUT"
    fi
    TX_SIZE=$((250 + 100 * (SELECTED_COUNT - 1)))
    FEE=$(echo "$FEE_RATE * $TX_SIZE" | bc -l)
    TOTAL_NEEDED=$(echo "$AMOUNT_TO_SEND + $FEE" | bc -l)
    if (( $(echo "$SELECTED_AMOUNT >= $TOTAL_NEEDED" | bc -l) )); then
      break
    fi
  done
  if (( $(echo "$SELECTED_AMOUNT < $TOTAL_NEEDED" | bc -l) )); then
    echo "Error: Unable to select enough UTXOs. Selected: $SELECTED_AMOUNT, Needed: $TOTAL_NEEDED"
    return 1
  fi
  CHANGE=$(echo "$SELECTED_AMOUNT - $AMOUNT_TO_SEND - $FEE" | bc -l)
  if (( $(echo "$CHANGE < 0" | bc -l) )); then
    echo "Error: Insufficient funds selected for amount + fee. Selected: $SELECTED_AMOUNT, Requested: $AMOUNT_TO_SEND, Fee: $FEE"
    return 1
  fi
  echo "Creating raw transaction with $SELECTED_COUNT UTXOs..."
  echo "Debug: Using INPUT_JSON: $INPUT_JSON"
  OUTPUTS_JSON=$(echo "{}" | jq -c --arg addr1 "$DESTINATION_ADDRESS" --argjson amt1 "$AMOUNT_TO_SEND" --arg addr2 "$P2SH_ADDRESS" --argjson amt2 "$CHANGE" '. + {($addr1): $amt1, ($addr2): $amt2}')
  echo "Debug: Using OUTPUTS_JSON: $OUTPUTS_JSON"
  RAW_TX=$($BINARY createrawtransaction "$INPUT_JSON" "$OUTPUTS_JSON" 2>/dev/null)
  if [ -z "$RAW_TX" ]; then
    echo "Error: Failed to create raw transaction. Check inputs or $BINARY."
    return 1
  fi
  echo "Signing with private key (partial signature)..."
  # Properly format the inputs as a JSON array
  INPUTS_ARRAY="[$INPUTS]"
  echo "Debug: Using inputs array for signing: $INPUTS_ARRAY"
  SIGNED_TX=$($BINARY signrawtransaction "$RAW_TX" "$INPUTS_ARRAY" "[\"$PRIVATE_KEY\"]" 2>/dev/null)
  if [ -z "$SIGNED_TX" ]; then
    echo "Error: Failed to sign transaction. Check private key, transaction hex, or inputs."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')
  DECODED=$($BINARY decoderawtransaction "$SIGNED_HEX" 2>/dev/null)
  if [ -z "$DECODED" ]; then
    echo "Error: Failed to decode signed transaction."
    return 1
  fi
  # Count signatures in all inputs
  SIG_COUNT=0
  VIN_COUNT=$(echo "$DECODED" | jq -r '.vin | length')
  for i in $(seq 0 $((VIN_COUNT - 1))); do
    INPUT_SIGS=$(echo "$DECODED" | jq -r ".vin[$i].scriptSig.asm" | tr ' ' '\n' | grep -E '^[0-9a-fA-F]{60,144}$' | wc -l)
    SIG_COUNT=$((SIG_COUNT + INPUT_SIGS))
  done
  JSON_FILE="tx_create_$(date +%Y%m%d_%H%M%S).json"
  echo "Saving transaction details to $JSON_FILE..."
  # Format the JSON file with proper inputs array
  echo "{\"p2sh_address\":\"$P2SH_ADDRESS\", \"redeem_script\":\"$REDEEM_SCRIPT\", \"inputs\":[$INPUTS], \"signed_hex\":\"$SIGNED_HEX\", \"complete\":$COMPLETE, \"signatures\":$SIG_COUNT, \"required_signatures\":$REQSIGS}" > "$JSON_FILE"
  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed with $SIG_COUNT signatures!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Transaction details saved to: $JSON_FILE"
    echo "Use 'Broadcast Final Transaction' with this file or hex to send it."
  else
    echo "Partial signature complete. $SIG_COUNT of $REQSIGS signatures provided."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Transaction details saved to: $JSON_FILE"
    echo "Share $JSON_FILE or the following with another signer:"
    echo "Hex: $SIGNED_HEX"
    echo "Inputs for signing: [$INPUTS]"
    echo "Command: $BINARY signrawtransaction \"$SIGNED_HEX\" \"$INPUTS\" \"[<private key 2>]\""
    if [ "$SIG_COUNT" -lt "$REQSIGS" ]; then
      echo "Warning: Still need $(($REQSIGS - $SIG_COUNT)) more signature(s) to complete!"
    fi
  fi
}

# Function to sign a partial transaction
sign_partial_tx() {
  echo "=== Sign Partial Transaction ==="
  if [ -n "$P2SH_ADDRESS" ]; then
    echo "Using P2SH address: $P2SH_ADDRESS"
  else
    read -p "Enter P2SH address: " P2SH_ADDRESS
  fi
  if [ -n "$REDEEM_SCRIPT" ]; then
    echo "Using redeem script: $REDEEM_SCRIPT"
  else
    read -p "Enter redeem script: " REDEEM_SCRIPT
  fi
  if [ -n "$PRIVATE_KEY" ]; then
    echo "Using private key: [hidden]"
  else
    read -p "Enter your private key: " PRIVATE_KEY
  fi
  read -p "Use JSON file for input? (y/n): " USE_JSON
  if [ "$USE_JSON" = "y" ]; then
    read -p "Enter JSON file path: " JSON_FILE
    if [ ! -f "$JSON_FILE" ]; then
      echo "Error: File $JSON_FILE not found."
      return 1
    fi
    RAW_TX=$(jq -r '.signed_hex' "$JSON_FILE")
    INPUTS=$(jq -r '.inputs' "$JSON_FILE")
    FILE_P2SH=$(jq -r '.p2sh_address' "$JSON_FILE")
    FILE_REDEEM=$(jq -r '.redeem_script' "$JSON_FILE")
    if [ -z "$RAW_TX" ] || [ -z "$INPUTS" ]; then
      echo "Error: Invalid JSON file. Missing signed_hex or inputs."
      return 1
    fi
    if [ "$FILE_P2SH" != "$P2SH_ADDRESS" ] || [ "$FILE_REDEEM" != "$REDEEM_SCRIPT" ]; then
      echo "Warning: P2SH address or redeem script in JSON differs from provided values."
      read -p "Proceed with JSON values? (y/n): " PROCEED
      if [ "$PROCEED" = "y" ]; then
        P2SH_ADDRESS="$FILE_P2SH"
        REDEEM_SCRIPT="$FILE_REDEEM"
      fi
    fi
    echo "Loaded transaction from $JSON_FILE"
  else
    read -p "Enter the partially signed transaction hex: " RAW_TX
    read -p "Enter the inputs JSON (from create step, e.g., [{\"txid\":..., \"vout\":...}]): " INPUTS
  fi
  if ! validate_p2sh_address "$P2SH_ADDRESS"; then
    return 1
  fi
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
  if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: No private key provided."
    return 1
  fi
  echo "Signing with private key (partial signature)..."
  # Make sure INPUTS is properly formatted as a JSON array
  echo "Debug: Using inputs for signing: $INPUTS"
  SIGNED_TX=$($BINARY signrawtransaction "$RAW_TX" "$INPUTS" "[\"$PRIVATE_KEY\"]" 2>/dev/null)
  if [ -z "$SIGNED_TX" ]; then
    echo "Error: Failed to sign transaction. Check private key, transaction hex, or inputs."
    return 1
  fi
  COMPLETE=$(echo "$SIGNED_TX" | jq -r '.complete')
  SIGNED_HEX=$(echo "$SIGNED_TX" | jq -r '.hex')
  DECODED=$($BINARY decoderawtransaction "$SIGNED_HEX" 2>/dev/null)
  if [ -z "$DECODED" ]; then
    echo "Error: Failed to decode signed transaction."
    return 1
  fi
  # Count signatures in all inputs
  SIG_COUNT=0
  VIN_COUNT=$(echo "$DECODED" | jq -r '.vin | length')
  for i in $(seq 0 $((VIN_COUNT - 1))); do
    INPUT_SIGS=$(echo "$DECODED" | jq -r ".vin[$i].scriptSig.asm" | tr ' ' '\n' | grep -E '^[0-9a-fA-F]{60,144}$' | wc -l)
    SIG_COUNT=$((SIG_COUNT + INPUT_SIGS))
  done
  JSON_FILE="tx_sign_$(date +%Y%m%d_%H%M%S).json"
  echo "Saving transaction details to $JSON_FILE..."
  # Format the JSON file with proper inputs
  echo "{\"p2sh_address\":\"$P2SH_ADDRESS\", \"redeem_script\":\"$REDEEM_SCRIPT\", \"inputs\":$INPUTS, \"signed_hex\":\"$SIGNED_HEX\", \"complete\":$COMPLETE, \"signatures\":$SIG_COUNT, \"required_signatures\":$REQSIGS}" > "$JSON_FILE"
  if [ "$COMPLETE" == "true" ]; then
    echo "Transaction fully signed with $SIG_COUNT signatures!"
    echo "Signed transaction hex: $SIGNED_HEX"
    echo "Transaction details saved to: $JSON_FILE"
    echo "Use 'Broadcast Final Transaction' with this file or hex to send it."
  else
    echo "Partial signature complete. $SIG_COUNT of $REQSIGS signatures provided."
    echo "Partially signed transaction hex: $SIGNED_HEX"
    echo "Transaction details saved to: $JSON_FILE"
    echo "Share $JSON_FILE or the following with another signer:"
    echo "Hex: $SIGNED_HEX"
    echo "Inputs for signing: $INPUTS"
    echo "Command: $BINARY signrawtransaction \"$SIGNED_HEX\" \"$INPUTS\" \"[<private key 2>]\""
    if [ "$SIG_COUNT" -lt "$REQSIGS" ]; then
      echo "Warning: Still need $(($REQSIGS - $SIG_COUNT)) more signature(s) to complete!"
    fi
  fi
}

# Function to broadcast the final transaction
broadcast_final_tx() {
  echo "=== Broadcast Final Transaction ==="
  read -p "Use JSON file for input? (y/n): " USE_JSON
  if [ "$USE_JSON" = "y" ]; then
    read -p "Enter JSON file path: " JSON_FILE
    if [ ! -f "$JSON_FILE" ]; then
      echo "Error: File $JSON_FILE not found."
      return 1
    fi
    SIGNED_HEX=$(jq -r '.signed_hex' "$JSON_FILE")
    COMPLETE=$(jq -r '.complete' "$JSON_FILE")
    if [ -z "$SIGNED_HEX" ]; then
      echo "Error: Invalid JSON file. Missing signed_hex."
      return 1
    fi
    if [ "$COMPLETE" != "true" ]; then
      echo "Error: Transaction in $JSON_FILE is not fully signed (complete: $COMPLETE)."
      return 1
    fi
    echo "Loaded transaction from $JSON_FILE"
  else
    read -p "Enter the transaction hex: " SIGNED_HEX
  fi
  if [ -z "$SIGNED_HEX" ]; then
    echo "Error: No transaction hex provided."
    return 1
  fi
  echo "Sending transaction..."
  TXID=$($BINARY sendrawtransaction "$SIGNED_HEX" 2>&1)
  if [[ "$TXID" =~ ^error ]]; then
    echo "Error: Failed to send transaction: $TXID"
    return 1
  fi
  echo "Success! Transaction ID: $TXID"
  echo "Check status with: $BINARY gettransaction \"$TXID\""
}

# Main menu
while true; do
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
