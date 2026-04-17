from __future__ import annotations

from typing import List

from ..models import LayerClass


PAIR_MAP = {
    LayerClass.OPAQUE: LayerClass.OPAQUE_LOD,
    LayerClass.ALPHA1: LayerClass.ALPHA1_LOD,
    LayerClass.ALPHA2: LayerClass.ALPHA2_LOD,
    LayerClass.ALPHA3: LayerClass.ALPHA3_LOD,
    LayerClass.ALPHA4: LayerClass.ALPHA4_LOD,
    LayerClass.ALPHA5: LayerClass.ALPHA5_LOD,
}


class LayerPolicy:
    def classify(self, layer_name: str) -> LayerClass:
        for layer_class in (
            LayerClass.OPAQUE,
            LayerClass.ALPHA1,
            LayerClass.ALPHA2,
            LayerClass.ALPHA3,
            LayerClass.ALPHA4,
            LayerClass.ALPHA5,
            LayerClass.OPAQUE_LOD,
            LayerClass.ALPHA1_LOD,
            LayerClass.ALPHA2_LOD,
            LayerClass.ALPHA3_LOD,
            LayerClass.ALPHA4_LOD,
            LayerClass.ALPHA5_LOD,
        ):
            if layer_name == layer_class.value:
                return layer_class
        return LayerClass.UNKNOWN

    def select_indices(self, layer_names: List[str], fidelity: str) -> List[int]:
        if fidelity == "raw":
            return list(range(len(layer_names)))

        classes = [self.classify(name) for name in layer_names]
        selected = set(range(len(layer_names)))
        lod_classes = set(PAIR_MAP.values())
        for idx, cls in enumerate(classes):
            if cls in lod_classes:
                selected.discard(idx)

        for normal_class, lod_class in PAIR_MAP.items():
            normal_indices = [i for i, cls in enumerate(classes) if cls == normal_class]
            lod_indices = [i for i, cls in enumerate(classes) if cls == lod_class]
            if normal_indices and lod_indices:
                for idx in lod_indices:
                    selected.discard(idx)
        return sorted(selected)
