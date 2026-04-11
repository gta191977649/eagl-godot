from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Optional

from .models import ShaderField


class ShaderLibrary:
    shader_pattern = re.compile(
        r'\{\s*"(?P<name>[^"]+)"\s*,\s*\d+\s*,\s*\{(?P<decl>(?:\s*\{\s*Shader::\w+\s*,\s*Shader::\w+\s*\}\s*,?)*)\s*\}\s*,\s*\{',
        re.S,
    )
    field_pattern = re.compile(r"\{\s*Shader::(?P<type>\w+)\s*,\s*Shader::(?P<usage>\w+)\s*\}")

    def __init__(self, source: Path) -> None:
        self.shaders: Dict[str, List[ShaderField]] = {}
        text = source.read_text(encoding="utf-8", errors="ignore")
        for match in self.shader_pattern.finditer(text):
            name = match.group("name")
            decl_text = match.group("decl")
            fields: List[ShaderField] = []
            for field_match in self.field_pattern.finditer(decl_text):
                fields.append(
                    ShaderField(
                        decl_type=field_match.group("type"),
                        usage=field_match.group("usage"),
                    )
                )
            if fields:
                self.shaders[name] = fields

    def get(self, name: str) -> Optional[List[ShaderField]]:
        return self.shaders.get(name)
