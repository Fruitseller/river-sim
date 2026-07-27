/*
====================================================================================

Supplemental noise texture used to add diffuse/normal detail.

Derived from https://www.shadertoy.com/view/7ljcRW by Fewes.

====================================================================================
*/

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    if (DISCARD_MAP) {
        return;
    }

    vec2 uv = fragCoord / BUFFER_SIZE;
    uv += TIME_SCROLL_OFFSET_INT;
    
    vec3 color = vec3(0.0);
    
    float a = 0.5;
    float f = 2.0;
    for (int i = 0; i < 8; i++) {
        color += noised(uv * f) * a;
        a *= 0.95;
        f *= 2.0;
    }

    fragColor = vec4(color, 1.0);
}
