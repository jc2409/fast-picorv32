import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.linear_model import LinearRegression
import os

# ------------------------------------------------------------
# Load data (assumes CSV is one level above script directory)
# ------------------------------------------------------------
csv_path = os.path.join(os.path.dirname(__file__), '..', 'results.csv')
if not os.path.exists(csv_path):
    # fallback: try current working directory
    csv_path = 'results.csv'
df = pd.read_csv(csv_path)

# ------------------------------------------------------------
# Define columns of interest
# ------------------------------------------------------------
binary_params = ['barrel_shifter', 'enable_mul', 'enable_div',
                 'enable_fast_mul', 'enable_counters', 'enable_irq']
metrics = ['luts', 'ffs', 'brams', 'carry_cells', 'fmax_mhz', 'logic_levels']

# Ensure all columns exist
for col in binary_params + metrics:
    if col not in df.columns:
        raise KeyError(f"Column '{col}' not found in CSV. Available: {df.columns.tolist()}")

# ------------------------------------------------------------
# 1. Correlation matrix (binary params vs metrics)
# ------------------------------------------------------------
corr_data = df[binary_params + metrics]
corr_matrix = corr_data.corr()
# Keep only correlations between binary params and metrics
param_metric_corr = corr_matrix.loc[binary_params, metrics]

# Save to CSV
param_metric_corr.to_csv(os.path.join(os.path.dirname(__file__), 'correlation_params_metrics.csv'))
print("Saved correlation matrix (params vs metrics).")

# Plot heatmap
plt.figure(figsize=(10, 6))
sns.heatmap(param_metric_corr, annot=True, cmap='coolwarm', center=0, fmt='.2f')
plt.title('Correlation between Binary Parameters and PPA Metrics')
plt.tight_layout()
plt.savefig(os.path.join(os.path.dirname(__file__), 'correlation_heatmap.png'))
plt.close()

# ------------------------------------------------------------
# 2. Mean difference when enabling each parameter
# ------------------------------------------------------------
diff_results = []
for param in binary_params:
    mean0 = df[df[param]==0]['luts'].mean()
    mean1 = df[df[param]==1]['luts'].mean()
    diff_results.append({
        'parameter': param,
        'luts_0_mean': mean0,
        'luts_1_mean': mean1,
        'luts_increase': mean1 - mean0,
        'fmax_0_mean': df[df[param]==0]['fmax_mhz'].mean(),
        'fmax_1_mean': df[df[param]==1]['fmax_mhz'].mean(),
        'fmax_change': df[df[param]==1]['fmax_mhz'].mean() - df[df[param]==0]['fmax_mhz'].mean()
    })
diff_df = pd.DataFrame(diff_results)
diff_df.to_csv(os.path.join(os.path.dirname(__file__), 'mean_differences.csv'), index=False)
print("Saved mean differences (LUTs and Fmax when enabling each param).")

# ------------------------------------------------------------
# 3. Linear regression for LUTs and Fmax
# ------------------------------------------------------------
X = df[binary_params]
y_luts = df['luts']
y_fmax = df['fmax_mhz']

reg_luts = LinearRegression().fit(X, y_luts)
reg_fmax = LinearRegression().fit(X, y_fmax)

coef_luts = pd.Series(reg_luts.coef_, index=binary_params)
coef_fmax = pd.Series(reg_fmax.coef_, index=binary_params)

reg_results = pd.DataFrame({
    'parameter': binary_params,
    'coef_luts': coef_luts.values,
    'coef_fmax_mhz': coef_fmax.values
})
reg_results.to_csv(os.path.join(os.path.dirname(__file__), 'linear_regression_coefficients.csv'), index=False)
print("Saved linear regression coefficients (marginal effect of each param).")

# ------------------------------------------------------------
# 4. Bar plot of LUTs per configuration (sorted)
# ------------------------------------------------------------
df_sorted = df.sort_values('luts')
plt.figure(figsize=(14, 8))
plt.barh(df_sorted['config'], df_sorted['luts'], color='steelblue')
plt.xlabel('LUTs')
plt.title('LUT usage per RISC-V configuration')
plt.tight_layout()
plt.savefig(os.path.join(os.path.dirname(__file__), 'luts_per_config.png'))
plt.close()

# ------------------------------------------------------------
# 5. Scatter plot: LUTs vs Fmax, coloured by number of enabled features
# ------------------------------------------------------------
df['num_features'] = df[binary_params].sum(axis=1)
plt.figure(figsize=(8, 6))
sc = plt.scatter(df['luts'], df['fmax_mhz'], c=df['num_features'], cmap='viridis', edgecolors='k')
plt.colorbar(sc, label='Number of enabled features')
plt.xlabel('LUTs')
plt.ylabel('Fmax (MHz)')
plt.title('Area vs. Performance trade-off')
plt.grid(True)
plt.tight_layout()
plt.savefig(os.path.join(os.path.dirname(__file__), 'luts_vs_fmax.png'))
plt.close()

print("\nAll analysis complete. Results saved in:", os.path.dirname(__file__))
