#!/usr/bin/env python3
"""
PPA analysis script – identifies which CPU parameter enables drive area, frequency, etc.
Works with the CSV output of run_ppa_fixed.py.
"""

import argparse
import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.ensemble import RandomForestRegressor
from sklearn.decomposition import PCA
from sklearn.preprocessing import StandardScaler

# ----------------------------------------------------------------------
# Configuration – adjust these lists to match your CSV columns exactly
# ----------------------------------------------------------------------

# The boolean parameters (0/1) that you want to study.
# NOTE: 'enable_irqtwo_stage_shift' is a single column in your CSV.
#       If it should be two separate columns (enable_irq, two_stage_shift),
#       split them manually first or rename accordingly.
PARAMS = [
    'barrel_shifter', 'enable_mul', 'enable_div', 'enable_counters',
    'enable_compressed', 'enable_irqtwo_stage_shift', 'two_cycle_compare',
    'two_cycle_alu', 'enable_regs_dualport', 'enable_counters64',
    'catch_misalign', 'catch_illinsn', 'latched_mem_rdata',
    'use_clk_divider', 'enable_irq_qregs', 'enable_fast_mul'
]

# All numeric metrics available in your CSV
METRICS = [
    'luts', 'ffs', 'brams', 'dsps', 'carry_cells', 'fmax_mhz',
    'logic_levels', 'lc_used', 'lc_percent', 'ram_used', 'ram_percent',
    'dsp_used', 'dsp_percent', 'io_used', 'io_percent',
    'pll_used', 'pll_percent', 'gb_used', 'gb_percent'
]

# Focus on the most important ones for readability
KEY_METRICS = ['luts', 'fmax_mhz', 'ffs', 'brams', 'dsps', 'logic_levels']

# A parameter to use as hue in pairplot / PCA (choose one with large impact)
HUE_PARAM = 'barrel_shifter'

# Two parameters to combine for the interaction boxplot
BOX_PARAM1 = 'barrel_shifter'
BOX_PARAM2 = 'enable_counters'
BOX_METRIC = 'fmax_mhz'

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------

def load_data(csv_path):
    """Read the CSV and return a DataFrame."""
    df = pd.read_csv(csv_path)
    print(f"Loaded {len(df)} rows.")
    return df

def preprocess(df):
    """Filter out configurations that did not go through synthesis (luts == 0)."""
    initial = len(df)
    df = df[df['luts'] > 0].copy()
    print(f"Removed {initial - len(df)} rows with zero LUTs (synthesis skipped/failed).")
    return df

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)

# ----------------------------------------------------------------------
# Analysis 1: average effect bar charts
# ----------------------------------------------------------------------
def plot_average_effects(df, params, metrics, out_dir):
    """For each metric, draw a bar chart of mean value when each param is OFF/ON."""
    out_path = os.path.join(out_dir, '01_average_effects.png')
    n_params = len(params)
    n_metrics = len(metrics)

    fig, axes = plt.subplots(n_metrics, n_params, figsize=(n_params*2.5, n_metrics*2.5))
    # Make sure axes is 2D
    if n_metrics == 1:
        axes = axes.reshape(1, -1)
    if n_params == 1:
        axes = axes.reshape(-1, 1)

    for i, metric in enumerate(metrics):
        for j, param in enumerate(params):
            ax = axes[i, j]
            grouped = df.groupby(param)[metric].mean()
            # Ensure both 0 and 1 are present
            if 0 not in grouped.index or 1 not in grouped.index:
                ax.text(0.5, 0.5, 'Only one\nvalue', ha='center', va='center', transform=ax.transAxes)
                ax.set_title(f'{param}')
                continue
            means = [grouped.get(0, 0), grouped.get(1, 0)]
            ax.bar(['OFF', 'ON'], means, color=['gray', 'steelblue'])
            ax.set_title(f'{param}')
            ax.set_ylabel(metric if j == 0 else '')
            ax.tick_params(axis='x', rotation=45)
    plt.suptitle('Average metric value when parameter is OFF vs ON', fontsize=14)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Average effect bar charts saved to {out_path}")

# ----------------------------------------------------------------------
# Analysis 2: correlation heatmap
# ----------------------------------------------------------------------
def plot_correlation_heatmap(df, params, metrics, out_dir):
    """Correlation matrix between parameters and metrics."""
    out_path = os.path.join(out_dir, '02_correlation_heatmap.png')
    corr = df[params + metrics].corr()
    # Focus on metrics vs parameters: extract only the rows/cols we care about
    # We'll show full matrix but maybe it's large; plot just params vs metrics
    plt.figure(figsize=(max(len(metrics)*1.2, 8), max(len(params)*0.6, 6)))
    sub_corr = corr.loc[params, metrics]
    sns.heatmap(sub_corr, annot=True, fmt=".2f", cmap='coolwarm', center=0,
                linewidths=0.5, cbar_kws={'label': 'Pearson correlation'})
    plt.title('Correlation: Parameters vs Metrics')
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Correlation heatmap saved to {out_path}")

# ----------------------------------------------------------------------
# Analysis 3: feature importance with Random Forest
# ----------------------------------------------------------------------
def plot_feature_importance(df, params, metrics, out_dir):
    """Train a Random Forest for each metric and plot parameter importances."""
    out_path = os.path.join(out_dir, '03_feature_importance.png')
    n_metrics = len(metrics)
    fig, axes = plt.subplots(1, n_metrics, figsize=(n_metrics*5, 5))
    if n_metrics == 1:
        axes = [axes]

    for ax, metric in zip(axes, metrics):
        X = df[params].fillna(0)
        y = df[metric]
        model = RandomForestRegressor(n_estimators=100, random_state=42, n_jobs=-1)
        model.fit(X, y)
        importances = pd.Series(model.feature_importances_, index=params).sort_values()
        importances.plot(kind='barh', ax=ax, color='teal')
        ax.set_title(f'Importance for {metric}')
        ax.set_xlabel('Importance')
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Feature importance plots saved to {out_path}")

    # Print top 5 for LUTs and Fmax
    for metric in ['luts', 'fmax_mhz']:
        if metric in metrics:
            X = df[params].fillna(0)
            y = df[metric]
            model = RandomForestRegressor(n_estimators=100, random_state=42, n_jobs=-1)
            model.fit(X, y)
            imp = pd.Series(model.feature_importances_, index=params).sort_values(ascending=False)
            print(f"\nTop 5 parameters for {metric}:")
            print(imp.head(5).to_string())

# ----------------------------------------------------------------------
# Analysis 4: pairplot for key metrics
# ----------------------------------------------------------------------
def plot_pairplot(df, metrics_subset, hue_param, out_dir):
    """Pairplot of selected metrics, coloured by hue_param."""
    out_path = os.path.join(out_dir, '04_pairplot.png')
    sns.pairplot(df, vars=metrics_subset, hue=hue_param, diag_kind='kde',
                 plot_kws={'alpha': 0.7})
    plt.suptitle(f'Pairplot of key metrics (hue = {hue_param})', y=1.02)
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Pairplot saved to {out_path}")

# ----------------------------------------------------------------------
# Analysis 5: Interaction boxplot
# ----------------------------------------------------------------------
def plot_interaction_boxplot(df, metric, param1, param2, out_dir):
    """Box plot showing combined effect of two binary parameters."""
    out_path = os.path.join(out_dir, '05_interaction_boxplot.png')
    df_plot = df.copy()
    df_plot['combined'] = df_plot[param1].astype(str) + '_' + df_plot[param2].astype(str)
    plt.figure(figsize=(8,5))
    order = ['0_0', '0_1', '1_0', '1_1']
    labels = [f'{param1}=0\n{param2}=0', f'{param1}=0\n{param2}=1',
              f'{param1}=1\n{param2}=0', f'{param1}=1\n{param2}=1']
    sns.boxplot(x='combined', y=metric, data=df_plot, order=order)
    plt.xticks(range(4), labels, fontsize=9)
    plt.title(f'Interaction of {param1} and {param2} on {metric}')
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Interaction boxplot saved to {out_path}")

# ----------------------------------------------------------------------
# Analysis 6: PCA of metrics
# ----------------------------------------------------------------------
def plot_pca(df, metrics, hue_param, out_dir):
    """Reduce metrics to 2D using PCA and color by a parameter."""
    out_path = os.path.join(out_dir, '06_pca.png')
    X = df[metrics].dropna()
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    pca = PCA(n_components=2)
    components = pca.fit_transform(X_scaled)
    pca_df = pd.DataFrame(components, columns=['PC1', 'PC2'])
    pca_df[hue_param] = df[hue_param].values

    plt.figure(figsize=(8,6))
    sns.scatterplot(data=pca_df, x='PC1', y='PC2', hue=hue_param, alpha=0.8)
    plt.title(f'PCA of PPA metrics (colored by {hue_param})')
    explained = pca.explained_variance_ratio_ * 100
    plt.xlabel(f'PC1 ({explained[0]:.1f}%)')
    plt.ylabel(f'PC2 ({explained[1]:.1f}%)')
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"PCA plot saved to {out_path}")
    print(f"  Explained variance: PC1={explained[0]:.1f}%, PC2={explained[1]:.1f}%")

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='Analyse PPA CSV to find parameter effects.')
    parser.add_argument('csv', nargs='?', default='ppa_config_fixed.csv',
                        help='Path to the CSV file (default: ppa_config_fixed.csv)')
    parser.add_argument('--outdir', '-o', default='analysis_output',
                        help='Output directory for plots (default: analysis_output)')
    args = parser.parse_args()

    df = load_data(args.csv)
    df = preprocess(df)

    ensure_dir(args.outdir)

    # 1. Average effects
    plot_average_effects(df, PARAMS, KEY_METRICS, args.outdir)

    # 2. Correlation heatmap
    plot_correlation_heatmap(df, PARAMS, KEY_METRICS, args.outdir)

    # 3. Feature importance (all KEY_METRICS)
    plot_feature_importance(df, PARAMS, KEY_METRICS, args.outdir)

    # 4. Pairplot of KEY_METRICS with hue
    plot_pairplot(df, KEY_METRICS, HUE_PARAM, args.outdir)

    # 5. Interaction boxplot
    plot_interaction_boxplot(df, BOX_METRIC, BOX_PARAM1, BOX_PARAM2, args.outdir)

    # 6. PCA on KEY_METRICS
    plot_pca(df, KEY_METRICS, HUE_PARAM, args.outdir)

    print("\nAll analyses complete. Check the '{}' folder.".format(args.outdir))

if __name__ == "__main__":
    main()