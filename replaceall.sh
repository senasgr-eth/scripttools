#!/bin/bash

# Check if arguments are given
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 from_string to_string target_folder"
  exit 1
fi

FROM=$1
TO=$2
TARGET_DIR=$3

# Validate folder path
if [ ! -d "$TARGET_DIR" ]; then
  echo "❌ Error: '$TARGET_DIR' is not a valid directory."
  exit 1
fi

# Build case variations
declare -A CASE_MAP

# 1. lowercase → lowercase
CASE_MAP["$(echo "$FROM" | awk '{print tolower($0)}')"]="$(echo "$TO" | awk '{print tolower($0)}')"

# 2. Capitalized → Capitalized
CASE_MAP["$(echo "$FROM" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"]="$(echo "$TO" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"

# 3. MixedCase (e.g., DogeCoin style) → approx. same casing
FROM_MIXED="$(echo "$FROM" | sed -E 's/^(.)(.*)/\U\1\L\2/')"
TO_MIXED="$(echo "$TO" | sed -E 's/^(.)(.*)/\U\1\L\2/')"
CASE_MAP["$FROM_MIXED"]="$TO_MIXED"

# 4. UPPERCASE → UPPERCASE
CASE_MAP["$(echo "$FROM" | awk '{print toupper($0)}')"]="$(echo "$TO" | awk '{print toupper($0)}')"

# Start replacing
echo "🔁 Replacing in folder: $TARGET_DIR"
for FROM_CASE in "${!CASE_MAP[@]}"; do
  TO_CASE=${CASE_MAP[$FROM_CASE]}
  echo "🔄 Replacing: $FROM_CASE → $TO_CASE"

  grep -rl --exclude-dir=.git "$FROM_CASE" "$TARGET_DIR" | while read -r file; do
    sed -i "s/$FROM_CASE/$TO_CASE/g" "$file"
  done
done

echo "✅ All replacements complete."
