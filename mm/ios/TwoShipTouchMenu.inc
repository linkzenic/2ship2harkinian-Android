// Apple settings use CVars instead of Android's SharedPreferences.
static int touchMenuValues[22];
static constexpr const char* touchOptionKeys[] = {
    "gSettings.TouchControls.Size", "gSettings.TouchControls.Opacity",
    "gSettings.TouchControls.FloatingRightStick", "gSettings.TouchControls.TransparentSticks",
    "gSettings.TouchControls.GameCubeCamera", "gSettings.TouchControls.GameCubeTatl"
};
static constexpr int touchOptionDefaults[] = {1,2,1,0,2,0};
static constexpr int tatlLocations[]={14,7,5};

static TouchHud::Bindings IOSTouchBindings(int style) {
    TouchHud::Bindings bindings{};
    const int tatl=std::clamp(CVarGetInteger(touchOptionKeys[5],0),0,2);
    for (int i=0;i<TouchHud::BindingCount;++i) {
        int fallback = TouchHud::DefaultAction(style,i);
        if (style==2 && i==14) fallback=0;
        if (style==2 && i==tatlLocations[tatl]) fallback=TouchHud::Navi;
        bindings[i]=std::clamp(CVarGetInteger(TouchHud::BindingCvar(style,i),fallback),0,int(TouchHud::ActionCount)-1);
    }
    return bindings;
}
static void IntegratedTouchMenu(bool edit) {
    if (edit) { TwoShipIOS_EditIntegratedTouch(); return; }
    int style=std::clamp(CVarGetInteger("gSettings.TouchControls.Style",0),0,3);
    constexpr float scales[]={.75f,1.f,1.25f,1.5f}, opacity[]={.15f,.35f,.55f,.75f,1.f};
    TwoShipIOS_ConfigureIntegratedTouch(style,
        scales[std::clamp(CVarGetInteger(touchOptionKeys[0],1),0,3)],
        opacity[std::clamp(CVarGetInteger(touchOptionKeys[1],2),0,4)],
        CVarGetInteger("gSettings.TouchControls.FloatingLeftStick",1),
        CVarGetInteger(touchOptionKeys[2],1), CVarGetInteger(touchOptionKeys[3],0),
        CVarGetInteger(touchOptionKeys[4],2), IOSTouchBindings(style));
}
static bool SyncTouchMenu(int style, int index = -2, int value = 0) {
    if (style<1 || style>3) return false;
    auto bindings=IOSTouchBindings(style);
    if (index==-1) {
        for (int i=0;i<15;++i) CVarClear(TouchHud::BindingCvar(style,i));
        if (style==2) CVarClear(touchOptionKeys[5]);
    } else if (index>=0 && index<15 && value!=bindings[index]) {
        for (int i=0;i<15;++i)
            if(value!=0 && i!=index && !(style==3 && i==14) && bindings[i]==value)
                CVarSetInteger(TouchHud::BindingCvar(style,i),bindings[index]);
        CVarSetInteger(TouchHud::BindingCvar(style,index),value);
    } else if (index>=16 && index<22) {
        if (index==21 && style==2 && value>=0 && value<3) {
            const int destination=tatlLocations[value];
            for (int i=0;i<15;++i)
                if (i!=destination && bindings[i]==TouchHud::Navi)
                    CVarSetInteger(TouchHud::BindingCvar(style,i),bindings[destination]==TouchHud::Navi?0:bindings[destination]);
            CVarSetInteger(TouchHud::BindingCvar(style,destination),TouchHud::Navi);
        }
        CVarSetInteger(touchOptionKeys[index-16],value);
    }
    if (index!=-2) { CVarSave(); IntegratedTouchMenu(false); }
    bindings=IOSTouchBindings(style);
    std::copy(bindings.begin(),bindings.end(),touchMenuValues);
    for (int i=0;i<6;++i) touchMenuValues[i+16]=CVarGetInteger(touchOptionKeys[i],touchOptionDefaults[i]);
    return true;
}
