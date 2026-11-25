#include "../../mm/ios/TouchHudLayout.h"

#include <cassert>

int main() {
    using namespace TouchHud;
    constexpr std::array<float, 4> safe = {62, 0, 62, 21};
    constexpr float w=956, h=440;
    Layout layout;
    Placement placement;
    Bindings bindings{};
    layout.build(0,w,h,safe,1,32,false,true,placement,bindings);
    assert(layout.controls.empty());

    for (int style=1;style<=3;++style) {
        for (int i=0;i<BindingCount;++i) bindings[i]=DefaultAction(style,i);
        layout.build(style,w,h,safe,1,32,false,true,placement,bindings);
        assert(layout.find("a")->mask==0x8000);
        assert(layout.find("b")->mask==0x4000);
        assert(layout.find("du")->mask==0x800);
        auto* map=layout.find("map");
        auto* fairy=layout.find(style==3?"cu":"fairy");
        assert(map && map->mask==0x10000 && fairy && fairy->slot==8);
        assert(map->bounds.cy()==layout.find("settings")->bounds.cy());
        assert(map->bounds.cy()==fairy->bounds.cy());
        assert(map->bounds.cy()>h*.9f);
        assert(std::abs((map->bounds.cx()+fairy->bounds.cx())*.5f-w*.5f)<.001f);
        assert(std::abs(map->bounds.y+map->bounds.h-(h-safe[3]))<.001f);
        layout.build(style,w,h,safe,1,32|64,false,true,placement,bindings);
        assert(layout.find(style==3?"cu":"fairy")->mask==8);
        layout.build(style,w,h,safe,1,32,false,false,placement,bindings);
        assert(layout.controls.size()==1 && layout.find("eye"));
    }
    for (int i=0;i<BindingCount;++i) bindings[i]=DefaultAction(3,i);
    bindings[2]=DpadUp;
    bindings[9]=ItemLeft;
    placement.set("a",.7f,.6f,1.25f);
    layout.build(3,w,h,safe,1,32,false,true,placement,bindings);
    assert(layout.find("cl")->slot==4 && layout.find("du")->slot==1);
    assert(std::abs(layout.find("a")->bounds.cx()/w-.7f)<.001f);
}
