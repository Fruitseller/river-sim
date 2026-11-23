# Ozean-Shader: gültiger Alpha-Tiefenpass und Ausschnitt unter Land

Godot 4 nennt den Alpha-Tiefenpass `depth_prepass_alpha`. Der ähnlich klingende Vulkan-Begriff `depth_draw_alpha_prepass` kompiliert nicht und ließ den neuen Ozean erst beim Start der echten Szene ausfallen; ein Quelltext-Wächter fängt das headless.

Das Ozean-Mesh reicht über die Kamera-Sichtweite und zeichnet innerhalb der Terrainfläche nur über Meeresboden. Sonst sähe eine flache Kamera gleichzeitig seine quadratische Kante und die Platte unter dem Land.

Betrifft: `game/shaders/ocean.gdshader`, `RenderContractTests.testOceanUsesAValidAlphaDepthPrepass`, `RenderContractTests.testOceanClipsItsPlaneBelowLand`
