"""
Configuration management for Spock benchmark suite.
Supports YAML and JSON configuration files.
"""

import json
import yaml
from pathlib import Path
from typing import Any, Dict, Optional


class Config:
    """Configuration manager with file and environment variable support."""

    def __init__(self, config_file: Optional[Path] = None):
        """
        Initialize configuration.

        Args:
            config_file: Path to configuration file (YAML or JSON)
        """
        self._config: Dict[str, Any] = {}
        if config_file and config_file.exists():
            self.load_from_file(config_file)

    def load_from_file(self, config_file: Path) -> None:
        """
        Load configuration from file.

        Args:
            config_file: Path to configuration file
        """
        suffix = config_file.suffix.lower()
        with open(config_file, 'r') as f:
            if suffix in ['.yaml', '.yml']:
                self._config = yaml.safe_load(f) or {}
            elif suffix == '.json':
                self._config = json.load(f)
            else:
                raise ValueError(f"Unsupported config file format: {suffix}")

    def get(self, key: str, default: Any = None) -> Any:
        """
        Get configuration value using dot notation.

        Args:
            key: Configuration key (supports dot notation, e.g., 'proxmox.host')
            default: Default value if key not found

        Returns:
            Configuration value or default
        """
        keys = key.split('.')
        value = self._config
        for k in keys:
            if isinstance(value, dict) and k in value:
                value = value[k]
            else:
                return default
        return value

    def set(self, key: str, value: Any) -> None:
        """
        Set configuration value using dot notation.

        Args:
            key: Configuration key (supports dot notation)
            value: Value to set
        """
        keys = key.split('.')
        config = self._config
        for k in keys[:-1]:
            if k not in config:
                config[k] = {}
            config = config[k]
        config[keys[-1]] = value

    def update(self, updates: Dict[str, Any]) -> None:
        """
        Update configuration with dictionary.

        Args:
            updates: Dictionary of updates
        """
        self._config.update(updates)

    def to_dict(self) -> Dict[str, Any]:
        """Return configuration as dictionary."""
        return self._config.copy()
