import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.linear_model import LinearRegression
import os

# Load data
csv_file = 'ppa_config_fixed.csv'
if not os.path.exists(csv_file):
    print(f"ERROR: {csv_file} not found in current directory.")
    exit(1)

df = pd.read_csv(csv_file)

# Binary parameters and metrics
binary_params = ['barrel_shifter', 'enable_mul', 'enable_div',
                 'enable_fast_mul', 'enable_counters', 'enable_irq']
metrics = ['luts', 'ffs', 'brams', 'carry_cells', 'fmax_mhz', 'logic_levels']

# Create output folder
out_dir = 'ppa_analysis_output'
os.makedirs(out_dir, exist_ok=True)

# 1. Correlation matrix
corr = df[binary_params + metrics].corr()
param_metric_corr = corr.loc[binary_params, metrics]
param_metric_corr.to_csv(os.path.join(out_dir, 'correlation_params_metrics.csv'))
plt.figure(figsize=(10,6))
sns.heatmap(param_metric_corr, annot=True, cmap='coolwarm', center=0, fmt='.2f')
plt.title('Correlation between Binary Parameters and PPA Metrics')
plt.tight_layout()
plt.savefig(os.path.join(out_dir, 'correlation_heatmap.png'))
plt.close()

# 2. Mean differences
diff_list = []
for p in binary_params:
    mean0_luts = df[df[p]==0]['luts'].mean()
    mean1_luts = df[df[p]==1]['luts'].mean()
    mean0_fmax = df[df[p]==0]['fmax_mhz'].mean()
    mean1_fmax = df[df[p]==1]['fmax_mhz'].mean()
    diff_list.append({
        'parameter': p,
        'luts_0_mean': mean0_luts,
        'luts_1_mean': mean1_luts,
        'luts_increase': mean1_luts - mean0_luts,
        'fmax_0_mean': mean0_fmax,
        'fmax_1_mean': mean1_fmax,
        'fmax_change': mean1_fmax - mean0_fmax
    })
diff_df = pd.DataFrame(diff_list)
diff_df.to_csv(os.path.join(out_dir, 'mean_differences.csv'), index=False)

# 3. Linear regression
X = df[binary_params]
reg_luts = LinearRegression().fit(X, df['luts'])
reg_fmax = LinearRegression().fit(X, df['fmax_mhz'])
coef_df = pd.DataFrame({
    'parameter': binary_params,
    'coef_luts': reg_luts.coef_,
    'coef_fmax_mhz': reg_fmax.coef_
})
coef_df.to_csv(os.path.join(out_dir, 'linear_regression_coefficients.csv'), index=False)

# 4. Bar plot of LUTs per config
df_sorted = df.sort_values('luts')
plt.figure(figsize=(14,8))
plt.barh(df_sorted['config'], df_sorted['luts'], color='steelblue')
plt.xlabel('LUTs')
plt.title('LUT usage per RISC‑V configuration')
plt.tight_layout()
plt.savefig(os.path.join(out_dir, 'luts_per_config.png'))
plt.close()

# 5. Scatter LUTs vs Fmax, coloured by number of enabled features
df['num_features'] = df[binary_params].sum(axis=1)
plt.figure(figsize=(8,6))
sc = plt.scatter(df['luts'], df['fmax_mhz'], c=df['num_features'], cmap='viridis', edgecolors='k')
plt.colorbar(sc, label='Number of enabled features')
plt.xlabel('LUTs')
plt.ylabel('Fmax (MHz)')
plt.title('Area vs. Performance trade‑off')
plt.grid(True)
plt.tight_layout()
plt.savefig(os.path.join(out_dir, 'luts_vs_fmax.png'))
plt.close()

print(f"✅ Analysis complete. Results saved in '{out_dir}/'")
