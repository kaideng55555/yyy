#!/bin/bash

# YYY - Your Yearly Yearbook Script
# A simple utility to generate yearly summaries

# Color codes for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the year from argument or use current year
if [ -z "$1" ]; then
    YEAR=$(date +%Y)
else
    YEAR=$1
fi

# Validate year input
if ! [[ "$YEAR" =~ ^[0-9]{4}$ ]]; then
    echo "Error: Please provide a valid 4-digit year"
    exit 1
fi

# Print header
echo -e "${BLUE}=================================${NC}"
echo -e "${GREEN}   YYY - Your Yearly Yearbook${NC}"
echo -e "${BLUE}=================================${NC}"
echo ""

# Generate summary
echo -e "${YELLOW}Generating summary for year: $YEAR${NC}"
echo ""
echo "Summary generated on: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Year: $YEAR"
echo "Days in year: $(if [ $((YEAR % 4)) -eq 0 ] && { [ $((YEAR % 100)) -ne 0 ] || [ $((YEAR % 400)) -eq 0 ]; }; then echo 366; else echo 365; fi)"
echo "Is leap year: $(if [ $((YEAR % 4)) -eq 0 ] && { [ $((YEAR % 100)) -ne 0 ] || [ $((YEAR % 400)) -eq 0 ]; }; then echo Yes; else echo No; fi)"
echo ""

# Create output file
OUTPUT_FILE="summary_${YEAR}.txt"
{
    echo "====================================="
    echo "   YYY - Your Yearly Yearbook"
    echo "====================================="
    echo ""
    echo "Year: $YEAR"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Days in year: $(if [ $((YEAR % 4)) -eq 0 ] && { [ $((YEAR % 100)) -ne 0 ] || [ $((YEAR % 400)) -eq 0 ]; }; then echo 366; else echo 365; fi)"
    echo "Is leap year: $(if [ $((YEAR % 4)) -eq 0 ] && { [ $((YEAR % 100)) -ne 0 ] || [ $((YEAR % 400)) -eq 0 ]; }; then echo Yes; else echo No; fi)"
    echo ""
    echo "This is your yearly summary template."
    echo "Feel free to add your own notes and accomplishments!"
} > "$OUTPUT_FILE"

echo -e "${GREEN}✓ Summary saved to: $OUTPUT_FILE${NC}"
echo ""
echo -e "${BLUE}=================================${NC}"
echo "Thank you for using YYY!"
echo -e "${BLUE}=================================${NC}"
