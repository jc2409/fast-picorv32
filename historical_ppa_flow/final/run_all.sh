#!/bin/bash
# No 'set -e' – continue even if a config fails

if [ -f ~/oss-cad-suite/environment ]; then
    source ~/oss-cad-suite/environment
fi
export CROSS=riscv32-unknown-elf-

cd ~/final/picosoc

# Generate configs.csv (interactive, only generates, no PPA)
python3 interactive_ppa.py

# Loop over each configuration
for config in $(tail -n +2 configs.csv | cut -d, -f1); do
    echo "========== Processing $config =========="
    python3 run_ppa_fixed.py --config "$config"
    if [ $? -ne 0 ]; then
        echo "PPA failed for $config, skipping hardware benchmark."
        continue
    fi
    python3 run_hardware_bench.py --config "$config"
done

echo "All done. Results in ppa_config_fixed.csv and hardware_results.csv"
