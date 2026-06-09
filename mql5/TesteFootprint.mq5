//+------------------------------------------------------------------+
//|                                             TesteFootprint.mq5   |
//|                 Footprint Chart nativo MT5 — porta fiel do React |
//+------------------------------------------------------------------+
#property copyright "TesteFootprint"
#property version   "1.85"
#property description "Footprint Chart"
#property stacksize 4194304

#include <Canvas\Canvas.mqh>

//--- Formação
input group "=== Formação ==="
input string InpCloseMode      = "delta";   // Modo: delta|volume|range|time
input double InpDeltaMax       = 800;       // Delta máximo por cluster
input double InpVolumeMax      = 100000;    // Volume máximo (modo volume)
input double InpRangePoints    = 50;        // Range em pontos (modo range)
input int    InpTimeSeconds    = 300;       // Tempo em segundos (modo time)
input double InpStepMultiplier = 75.0;      // Agrupamento de níveis — 75 para USTEC
input int    InpHistoryBars    = 200;       // Clusters no buffer circular
input int    InpHistoryHours   = 4;         // Horas de histórico ao iniciar

//--- Exibição
input group "=== Exibição ==="
enum ENUM_VIEW { VIEW_BIDASK=0, VIEW_DELTA=1 };
input ENUM_VIEW InpViewMode    = VIEW_BIDASK; // Modo: Bid x Ask | Delta
input int    InpClusterWidth   = 120;       // Largura base do cluster (px)
input int    InpLevelHeight    = 16;        // Altura por nível (zoom vertical)
input int    InpFontSize       = 8;         // Tamanho da fonte
input int    InpBottomPanel    = 100;       // Altura do painel inferior (px) — igual React

//--- Cores
input group "=== Cores ==="
input color  InpColorAsk  = 0x3B82F6;
input color  InpColorBid  = 0xEC4899;
input color  InpColorPoc  = clrWhite;
input color  InpColorBg   = 0x0B0E14;
input color  InpColorText = 0x94A3B8;

//+------------------------------------------------------------------+
//| Estruturas                                                        |
//+------------------------------------------------------------------+
struct SLevel { double price, ask, bid; };

struct SCluster
{
    datetime open_time, close_time;
    double   open_price, close_price, delta, total_volume;
    double   price_high, price_low, poc_price;
    bool     is_closed;
    SLevel   levels[2000];
    int      level_count;
};

#define VP_LEVELS  500
#define ZONE_MAX   20
#define VP_MAX     5
// Color picker grid
#define PICK_COLS  16
#define PICK_ROWS  10
#define PICK_SW    14   // swatch width px
#define PICK_SH    14   // swatch height px
#define PICK_GAP   2    // gap between swatches
#define PICK_PAD   8    // panel padding
#define PICK_W     (PICK_PAD*2 + PICK_COLS*(PICK_SW+PICK_GAP) - PICK_GAP)  // 270
#define PICK_H     (32 + PICK_PAD + PICK_ROWS*(PICK_SH+PICK_GAP) - PICK_GAP + PICK_PAD)  // 206

struct SZone {
    double price_high, price_low;
    int    ci_from, ci_to;   // índices absolutos de histórico (ci_from <= ci_to)
    color  border_clr;
    bool   raio_dir;          // estende até a direita (borda do gráfico)
    bool   raio_esq;          // estende até a esquerda
    bool   sobre_clusters;    // z-order: desenha sobre os clusters
    bool   active;
};

struct SVProfile {
    double price_high, price_low;
    int    ci_from, ci_to;
    // Visualizar
    bool   show_volume;       // barras de volume
    bool   show_delta;        // barras de delta
    bool   delta_espelhado;   // delta espelhado (bid esquerda, ask direita)
    bool   volume_soma;       // soma bid+ask em barra única
    // Linhas
    bool   show_poc;
    bool   show_va;           // value area
    double va_pct;            // % value area (padrão 70)
    bool   show_vwap;
    // Z-order
    bool   sobre_clusters;
    // Cores
    color  clr_bid, clr_ask;  // cores das barras de volume
    color  clr_poc;           // linha do POC
    color  clr_borda;         // borda do painel
    // Dados calculados
    double prices[VP_LEVELS];
    double vol_bid[VP_LEVELS];
    double vol_ask[VP_LEVELS];
    int    count;
    double poc_price, vah_price, val_price, vwap_price;
    bool   active;
};

//+------------------------------------------------------------------+
//| Globais                                                           |
//+------------------------------------------------------------------+
SCluster  g_history[200];
int       g_history_count = 0;
int       g_history_start = 0;
SCluster  g_active;
bool      g_active_valid  = false;

double    g_tick_size  = 0.01;
double    g_step       = 1.0;
double    g_step_mult  = 1.0;
double    g_delta_max  = 800;
int       g_scroll     = 0;       // navegação L/R (em clusters)
int       g_zoom_v     = 16;      // altura de nível em px (drag barra de preço)
int       g_zoom_h     = 100;     // zoom horizontal % (drag painel inferior)
ulong     g_last_draw_msc = 0;

CCanvas   g_canvas;
string    g_canvas_name = "TesteFootprint_BMP";
int       g_canvas_w    = 0;
int       g_canvas_h    = 0;

ulong     g_last_tick_msc  = 0;
double    g_last_bid_price = 0;
double    g_last_mid_price = 0;
bool      g_last_is_buy    = true;
double    g_last_bid       = 0;
double    g_last_ask       = 0;
double    g_current_price  = 0;

// Drag: barra de preço → zoom vertical
bool      g_vaxis_drag = false;
int       g_vdrag_y0   = 0;
int       g_vdrag_z0   = 16;

// Drag: painel inferior → zoom horizontal
bool      g_haxis_drag = false;
int       g_hdrag_x0   = 0;
int       g_hdrag_zh0  = 100;

// Pan vertical (arrastar área principal)
bool      g_pan_drag   = false;
int       g_pan_y0     = 0;
double    g_pan_off0   = 0.0;
double    g_pan_offset = 0.0;   // offset em preço aplicado ao viewport
double    g_last_prange= 1.0;   // prange da última renderização (para converter px → preço)

// Runtime overrides (alterados pelo menu em tempo real)
ENUM_VIEW g_view_mode  = VIEW_BIDASK;
string    g_close_mode = "delta";
color     g_color_ask  = (color)0x3B82F6;
color     g_color_bid  = (color)0xEC4899;
color     g_color_poc  = clrWhite;

// Menu de configurações
bool   g_menu_open  = false;
int    g_menu_tab   = 0;         // 0=Formação 1=Cores
double g_form_step  = 75.0;
double g_form_delta = 800.0;
int    g_form_view  = 0;
string g_form_mode  = "delta";
bool   g_prev_btn   = false;     // estado anterior do botão (detecção de click)

// Ferramentas de desenho — Zona e VP
SZone     g_zones[ZONE_MAX];
int       g_zone_count = 0;
SVProfile g_vprofiles[VP_MAX];
int       g_vp_count    = 0;

// Estado do último Redraw — conversão pixel↔cluster/preço
int    g_rdr_cw=0, g_rdr_col_step=0, g_rdr_chart_x1=0, g_rdr_chart_h=0;
int    g_rdr_last_idx=0, g_rdr_active_off=0;
double g_rdr_pmin=0, g_rdr_pmax=0;

// Seleção de área para ferramentas de desenho (right-drag ou Ctrl+left-drag)
bool   g_rbtn_prev   = false;
bool   g_sel_drag    = false;
bool   g_sel_is_right= false;  // true=iniciado por right-drag, false=Ctrl+left-drag
int    g_sel_x0=0, g_sel_y0=0;
int    g_sel_x1=0, g_sel_y1=0;
bool   g_sel_ready   = false;
int    g_seltb_x=0, g_seltb_y=0;  // posição da toolbar (para hit-test)

// Presets de cor para o menu (cycling)
color g_bid_presets[] = {(color)0xEC4899,(color)0xFF1744,(color)0xEC464F,(color)0xE53935};
color g_ask_presets[] = {(color)0x3B82F6,(color)0x29B6F6,(color)0x3BA6F7,(color)0x1565C0};
color g_poc_presets[] = {clrWhite,(color)0xFFD600,(color)0x00E5FF,(color)0x76FF03};
int   g_bid_pi=0, g_ask_pi=0, g_poc_pi=0;

// Painel de configuração de zona
int   g_zone_sel   = -1;    // índice da zona selecionada, -1=nenhuma
bool  g_zone_panel = false; // painel de config aberto
int   g_zpx=0, g_zpy=0;    // posição do painel (ponto de clique)

color g_zone_clr_presets[] = {(color)0xFF4081,(color)0x3B82F6,(color)0x22C55E,
                               (color)0xFFD600,(color)0xEF4444,(color)0xA855F7};
int   g_zone_clr_pi=0;

// Painel de configuração de VP
int   g_vp_sel    = -1;
bool  g_vp_panel  = false;
int   g_vppx=0, g_vppy=0;

color g_vp_clr_presets[] = {(color)0xFFD600,(color)0xF59E0B,(color)0xFF4081,
                             (color)0x22C55E,(color)0x00E5FF};
int   g_vp_poc_pi=0;

// Right-click: distingue click (abre config) vs drag (inicia seleção)
bool g_rclick_wait = false;
int  g_rclick_xi=0, g_rclick_yi=0;
int  g_rclick_vi=-1;   // índice VP sob cursor no momento do right-press
int  g_rclick_zi=-1;   // índice Zone sob cursor no momento do right-press

// Color picker
enum EPICK_TARGET { PICK_NONE=0, PICK_ZONE_BORDER,
                    PICK_VP_BID, PICK_VP_ASK, PICK_VP_POC,
                    PICK_GLOBAL_BID, PICK_GLOBAL_ASK, PICK_GLOBAL_POC };
EPICK_TARGET g_pick_target = PICK_NONE;
bool g_pick_open = false;
int  g_pick_px=0, g_pick_py=0;

color g_pick_palette[160] = {
    // Row 0: Grayscale
    0x000000,0x111111,0x222222,0x333333,0x444444,0x666666,0x808080,0x999999,0xBBBBBB,0xCCCCCC,0xDDDDDD,0xEEEEEE,0xFFFFFF,0xF5F5DC,0xFFF8DC,0xFFFAF0,
    // Row 1: Red
    0xFF0000,0xFF1744,0xF50057,0xE53935,0xC62828,0xB71C1C,0x8B0000,0xFF5252,0xFF8A80,0xFFCDD2,0xFF4081,0xFC3158,0xE91E63,0xC2185B,0xAD1457,0x880E4F,
    // Row 2: Orange
    0xFF6600,0xFF5722,0xF4511E,0xE64A19,0xBF360C,0xFF3D00,0xFF6D00,0xFF9100,0xFFAB40,0xFF8C00,0xFFA726,0xFB8C00,0xF57C00,0xEF6C00,0xE65100,0xDD2C00,
    // Row 3: Yellow/Amber
    0xFFD600,0xFFEA00,0xFFFF00,0xFFF176,0xFFEB3B,0xFFC107,0xFFB300,0xFFA000,0xFF8F00,0xFF6F00,0xF9A825,0xF57F17,0xFDD835,0xF9D71C,0xFFEE58,0xFFF9C4,
    // Row 4: Green
    0x00C853,0x00E676,0x69F0AE,0x22C55E,0x4CAF50,0x43A047,0x388E3C,0x2E7D32,0x1B5E20,0x76FF03,0xB2FF59,0x8BC34A,0x558B2F,0x33691E,0x00BFA5,0x1DE9B6,
    // Row 5: Teal/Cyan
    0x00E5FF,0x18FFFF,0x00B8D4,0x00838F,0x00BCD4,0x00ACC1,0x0097A7,0x006064,0x009688,0x00897B,0x00796B,0x004D40,0x80DEEA,0x4DD0E1,0x26C6DA,0x84FFFF,
    // Row 6: Blue
    0x3B82F6,0x2563EB,0x1D4ED8,0x448AFF,0x2196F3,0x1976D2,0x1565C0,0x0D47A1,0x29B6F6,0x03A9F4,0x039BE5,0x0288D1,0x0277BD,0x01579B,0x82B1FF,0x40C4FF,
    // Row 7: Purple/Violet
    0xA855F7,0x9333EA,0x7E22CE,0x6200EA,0x651FFF,0x7C4DFF,0xD500F9,0xAA00FF,0xCE93D8,0xBA68C8,0xAB47BC,0x9C27B0,0x8E24AA,0x7B1FA2,0x4A148C,0x311B92,
    // Row 8: Pink/Magenta
    0xFF80AB,0xF48FB1,0xF06292,0xEC407A,0xE91E63,0xD81B60,0xC2185B,0xAD1457,0xFF4081,0xFF1744,0xF50057,0xC51162,0xD81B60,0xC2185B,0xAD1457,0x880E4F,
    // Row 9: Trading / acentos úteis
    0xFFD600,0xEC4899,0x3B82F6,0x22C55E,0xEF4444,0xA855F7,0x00E5FF,0xF97316,0x14B8A6,0x8B5CF6,0x6366F1,0x06B6D4,0x10B981,0xF59E0B,0x84CC16,0x795548
};

//+------------------------------------------------------------------+
//| Cores                                                             |
//+------------------------------------------------------------------+
uint Argb(color c, int a)
{ return ((uint)a<<24)|((c>>16)&0xFF)<<16|((c>>8)&0xFF)<<8|(c&0xFF); }

// Único jeito correto de semi-transparência em XRGB_NOALPHA
uint Blend(color bc, color bg, double t)
{
    t=MathMax(0.0,MathMin(1.0,t));
    uint r=(uint)(((bg>>16)&0xFF)*(1-t)+((bc>>16)&0xFF)*t);
    uint g=(uint)(((bg>>8)&0xFF)*(1-t)+((bc>>8)&0xFF)*t);
    uint b=(uint)((bg&0xFF)*(1-t)+(bc&0xFF)*t);
    return 0xFF000000|(r<<16)|(g<<8)|b;
}

//+------------------------------------------------------------------+
//| Cluster helpers                                                   |
//+------------------------------------------------------------------+
int CFindOrInsert(SCluster &c, double price)
{
    for(int i=0;i<c.level_count;i++) if(MathAbs(c.levels[i].price-price)<1e-8) return i;
    if(c.level_count>=2000) return -1;
    int pos=c.level_count;
    for(int i=0;i<c.level_count;i++) if(price<c.levels[i].price){pos=i;break;}
    for(int i=c.level_count;i>pos;i--) c.levels[i]=c.levels[i-1];
    c.levels[pos].price=price; c.levels[pos].ask=0; c.levels[pos].bid=0;
    c.level_count++; return pos;
}

void CCalcPoc(SCluster &c)
{
    // Usa max(ask,bid) — mesma métrica do local_max/barra — para que POC = nível sempre cheio
    double mx=-1; c.poc_price=(c.level_count>0)?c.levels[0].price:0;
    for(int i=0;i<c.level_count;i++){double t=MathMax(c.levels[i].ask,c.levels[i].bid);if(t>mx){mx=t;c.poc_price=c.levels[i].price;}}
}

void CAddVol(SCluster &c, double price, double volume, bool is_buy)
{
    double b=NormalizeDouble(MathRound(price/g_step)*g_step,_Digits);
    int idx=CFindOrInsert(c,b); if(idx<0) return;
    if(is_buy){c.levels[idx].ask+=volume;c.delta+=volume;}
    else      {c.levels[idx].bid+=volume;c.delta-=volume;}
    c.total_volume+=volume; c.close_price=price;
    if(c.level_count==1||b>c.price_high) c.price_high=b;
    if(c.level_count==1||b<c.price_low)  c.price_low=b;
}

void ActiveReset()
{
    g_active.open_time=0;g_active.close_time=0;g_active.open_price=0;g_active.close_price=0;
    g_active.delta=0;g_active.total_volume=0;g_active.price_high=0;g_active.price_low=0;
    g_active.poc_price=0;g_active.is_closed=false;g_active.level_count=0;g_active_valid=false;
}

int HIdx(int logical) { return (g_history_start + logical) % InpHistoryBars; }

void CloseActive(string reason)
{
    if(!g_active_valid) return;
    CCalcPoc(g_active); g_active.is_closed=true; g_active.close_time=(datetime)(g_last_tick_msc/1000);
    if(g_history_count < InpHistoryBars)
    {
        g_history[g_history_count] = g_active;
        g_history_count++;
    }
    else
    {
        g_history[g_history_start] = g_active;
        g_history_start = (g_history_start + 1) % InpHistoryBars;
    }
    ActiveReset();
}

bool ShouldClose(ulong msc)
{
    if(!g_active_valid) return false;
    if(g_close_mode=="delta")  return MathAbs(g_active.delta)>=g_delta_max;
    if(g_close_mode=="range")  return (g_active.price_high-g_active.price_low)>=InpRangePoints*g_tick_size;
    if(g_close_mode=="time")   return (msc/1000-(ulong)g_active.open_time)>=(ulong)InpTimeSeconds;
    if(g_close_mode=="volume") return g_active.total_volume>=InpVolumeMax;
    return false;
}

void ProcessTick(double price, double volume, bool is_buy, ulong msc)
{
    g_current_price=price;
    if(g_close_mode!="delta")
    {
        if(!g_active_valid){ActiveReset();g_active.open_time=(datetime)(msc/1000);g_active.open_price=price;g_active_valid=true;}
        CAddVol(g_active,price,volume,is_buy);
        if(ShouldClose(msc)) CloseActive(g_close_mode);
        return;
    }
    double rem=volume;
    while(rem>0.0)
    {
        if(g_active_valid&&MathAbs(g_active.delta)>=g_delta_max){CloseActive("delta");continue;}
        if(!g_active_valid){ActiveReset();g_active.open_time=(datetime)(msc/1000);g_active.open_price=price;g_active_valid=true;}
        double cur=g_active.delta,contrib=is_buy?rem:-rem;
        if(MathAbs(cur+contrib)<=g_delta_max){CAddVol(g_active,price,rem,is_buy);if(ShouldClose(msc))CloseActive("delta");break;}
        double cap=MathMax(is_buy?(g_delta_max-cur):(cur+g_delta_max),0.0);
        if(cap>0) CAddVol(g_active,price,cap,is_buy);
        CloseActive("delta"); rem-=cap;
    }
}

bool ClassifyTick(MqlTick &t)
{
    if((t.flags&TICK_FLAG_BUY) !=0) return true;
    if((t.flags&TICK_FLAG_SELL)!=0) return false;
    return g_last_is_buy;
}

bool ParseTick(MqlTick &t, double &p, double &v, bool &b)
{
    double bid=t.bid,ask=t.ask,last=t.last;
    if(bid>0) g_last_bid=bid;
    if(ask>0) g_last_ask=ask;
    double mid=(bid>0&&ask>0)?(bid+ask)/2.0:0;
    double pb=g_last_bid_price,pm=g_last_mid_price;
    if(bid>0){if(bid>g_last_bid_price)g_last_is_buy=true;else if(bid<g_last_bid_price)g_last_is_buy=false;g_last_bid_price=bid;}
    else if(mid>0){if(mid>g_last_mid_price)g_last_is_buy=true;else if(mid<g_last_mid_price)g_last_is_buy=false;}
    if(mid>0) g_last_mid_price=mid;
    p=(last>0)?last:(mid>0?mid:(bid>0?bid:ask));
    if(p<=0) return false;
    double ts=(g_tick_size>0)?g_tick_size:0.01;
    if(pb>0&&bid>0)     v=MathMax(MathAbs(bid-pb)/ts,1.0);
    else if(pm>0&&mid>0)v=MathMax(MathAbs(mid-pm)/ts,1.0);
    else                v=1.0;
    b=ClassifyTick(t); return true;
}

void Reload()
{
    g_step = g_tick_size * g_step_mult;
    g_pan_offset = 0.0;
    ActiveReset();
    g_history_count = 0;
    g_history_start = 0;
    g_last_bid_price = 0;
    g_last_mid_price = 0;
    g_last_is_buy    = true;
    LoadHistory();
    Redraw();
}

void LoadHistory()
{
    datetime from=TimeCurrent()-InpHistoryHours*3600;
    Print("TesteFootprint: carregando desde ",TimeToString(from));
    MqlTick ticks[];
    int count=CopyTicksRange(_Symbol,ticks,COPY_TICKS_ALL,(ulong)from*1000,(ulong)TimeCurrent()*1000);
    if(count<=0){Print("TesteFootprint: sem ticks históricos.");return;}
    Print("TesteFootprint: processando ",count," ticks...");
    for(int i=0;i<count;i++)
    {
        double p,v; bool b;
        g_last_tick_msc=ticks[i].time_msc;
        if(ParseTick(ticks[i],p,v,b)) ProcessTick(p,v,b,ticks[i].time_msc);
    }
    if(count>0) g_last_tick_msc=ticks[count-1].time_msc;
    Print("TesteFootprint: ",g_history_count," clusters prontos.");
}

//+------------------------------------------------------------------+
//| Canvas helpers                                                    |
//+------------------------------------------------------------------+
void TxtOut(int x, int y, string text, uint clr, string font="Arial", int sz=8)
{
    g_canvas.FontSet(font, sz);
    g_canvas.TextOut(x, y, text, clr);
}

bool ResizeCanvas()
{
    int w=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
    int h=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
    if(w==g_canvas_w&&h==g_canvas_h) return false;
    if(w<=0||h<=0) return false;
    g_canvas_w=w; g_canvas_h=h;
    g_canvas.Resize(w,h); return true;
}

//+------------------------------------------------------------------+
//| Renderiza cluster — porta fiel do React FootprintCanvas.jsx      |
//+------------------------------------------------------------------+
void DrawCluster(SCluster &c, int cx, int cw, int chart_h,
                 double pmin, double pmax, double max_side, bool is_active)
{
    if(c.level_count==0) return;
    double prange=pmax-pmin; if(prange<=0) return;

    int cw2 = cw - 4;  // largura interna (2px margem cada lado, como colX+1 no React)
    if(cw2<4) cw2=4;

    // Máximo local para proporção das barras (igual React: por cluster, não global)
    double local_max=1;
    for(int li=0;li<c.level_count;li++)
    {
        double d=MathMax(c.levels[li].ask,c.levels[li].bid);
        if(d>local_max)local_max=d;
    }

    // Body bounds para wick detection (open/close, igual React)
    double body_low =MathMin(c.open_price,c.close_price);
    double body_high=MathMax(c.open_price,c.close_price);
    bool   is_bull  =(c.close_price>=c.open_price);

    // row_h: espaçamento real entre níveis em px — igual ao React (rowHeight=zoomV, sem cap)
    double px_step=(g_step>0&&prange>0)?((double)(chart_h-4)*g_step/prange):(double)g_zoom_v;
    int row_h=MathMax(2,(int)px_step);

    //--- Células de nível (bid/ask bars) ---
    for(int li=0;li<c.level_count;li++)
    {
        double price=c.levels[li].price;
        double ask_v=c.levels[li].ask;
        double bid_v=c.levels[li].bid;
        double dom  =MathMax(ask_v,bid_v);
        bool   is_ask=(ask_v>=bid_v);

        int yc=chart_h-1-(int)((price-pmin)/prange*(chart_h-4));
        int yt=yc-row_h/2, yb=yt+row_h-1;
        if(yt<0)yt=0; if(yb>=chart_h)yb=chart_h-1; if(yt>=yb)continue;

        // Wick: fora do corpo → alpha 0.65, dentro → alpha 0.85
        // Tolerância = g_step*0.5 (igual React: actualTickSize = tick_size * stepMultiplier)
        bool   is_wick=(price<body_low-g_step*0.5)||(price>body_high+g_step*0.5);
        double alpha  =is_wick?0.65:0.85;

        // Barra proporcional lado dominante — igual em ambos os modos (fiel ao React)
        {
            int bw=(int)(dom/local_max*(double)cw2); if(bw<1)bw=1;
            g_canvas.FillRectangle(cx+2,yt+1,cx+2+bw-1,yb-1,
                Blend(is_ask?g_color_ask:g_color_bid,InpColorBg,alpha));
        }

        // POC: borda + número — sempre, inclusive no pavio
        // BidAsk: mostra dominantVal | Delta: mostra ask-bid com cor verde/vermelho
        if(MathAbs(price-c.poc_price)<1e-8)
        {
            g_canvas.Rectangle(cx+2,yt,cx+cw2+1,yb,Argb(g_color_poc,255));
            double delta_poc=ask_v-bid_v;
            string s=(g_view_mode==VIEW_DELTA)
                ? ((delta_poc>=0?"+":"")+IntegerToString((int)delta_poc))
                : IntegerToString((int)dom);
            uint txt_clr=(g_view_mode==VIEW_DELTA)
                ? Argb(delta_poc>=0?(color)0x00E676:(color)0xFF1744,255)
                : Argb(0xFFFFFF,255);
            g_canvas.FontSet("Arial Bold",InpFontSize);
            int tx=cx+cw2-(int)StringLen(s)*(InpFontSize-1);
            if(row_h>=InpFontSize)
                g_canvas.TextOut(tx,yt+(row_h-InpFontSize)/2,s,txt_clr);
        }

    }

    //--- Borda OHLC do cluster (open_price → close_price = CORPO) ---
    // Igual ao React: strokeRect ao redor do corpo, NÃO do high/low
    int y_open  =chart_h-1-(int)((c.open_price -pmin)/prange*(chart_h-4));
    int y_close =chart_h-1-(int)((c.close_price-pmin)/prange*(chart_h-4));
    int candle_top=MathMin(y_open,y_close)-row_h/2;
    int candle_bot=MathMax(y_open,y_close)+row_h/2;
    if(candle_top<0)candle_top=0;
    if(candle_bot>=chart_h)candle_bot=chart_h-1;
    if(candle_bot>candle_top)
        g_canvas.Rectangle(cx,candle_top,cx+cw,candle_bot,
            Blend(is_bull?(color)0x00E676:(color)0xFF1744,InpColorBg,0.55));

    //--- Linhas de pavio (centro da coluna, igual candle do React) ---
    int cx_mid=cx+cw/2;
    int y_high=chart_h-1-(int)((c.price_high-pmin)/prange*(chart_h-4));
    int y_low =chart_h-1-(int)((c.price_low -pmin)/prange*(chart_h-4));
    uint wick_clr=Blend(is_bull?(color)0x00E676:(color)0xFF1744,InpColorBg,0.4);
    if(c.price_high>body_high+g_tick_size*0.5&&y_high<candle_top)
        g_canvas.Line(cx_mid,y_high,cx_mid,candle_top,wick_clr);
    if(c.price_low <body_low -g_tick_size*0.5&&y_low >candle_bot)
        g_canvas.Line(cx_mid,candle_bot,cx_mid,y_low+row_h,wick_clr);


    //--- Painel inferior ---
    double total_bid=0,total_ask=0;
    for(int li=0;li<c.level_count;li++){total_bid+=c.levels[li].bid;total_ask+=c.levels[li].ask;}

    // Layout dinâmico: usa o espaço disponível do painel
    int panel_top  = chart_h + 2;                        // topo do painel (logo abaixo do separador)
    int ts_h       = 12;                                 // reserva p/ timestamp no fundo
    int panel_bot  = g_canvas_h - ts_h;                 // fundo disponível
    int panel_h    = panel_bot - panel_top;              // altura total usável
    if(panel_h < 10) return;

    int bar_zone_h = panel_h * 65 / 100;                // 65% p/ barras de volume
    int bar_base   = panel_top + bar_zone_h;             // piso das barras
    int pw         = cw;                                 // largura total da coluna (sem margens)
    int half_w     = pw / 2;

    int bid_bh=MathMax(2,(int)(total_bid/MathMax(max_side,1)*bar_zone_h));
    int ask_bh=MathMax(2,(int)(total_ask/MathMax(max_side,1)*bar_zone_h));

    // Bid (esquerda) e Ask (direita) — sem margem interna
    g_canvas.FillRectangle(cx,       bar_base-bid_bh, cx+half_w-1,  bar_base, Argb(0xD22626,255));
    g_canvas.FillRectangle(cx+half_w,bar_base-ask_bh, cx+pw-1,      bar_base, Argb(0x2563EB,255));

    // Label de volume dentro das barras
    double dom_vol=MathMax(total_bid,total_ask);
    string vol_lbl=(dom_vol>=1000)?(DoubleToString(dom_vol/1000.0,1)+"K"):IntegerToString((int)dom_vol);
    int vol_fs=MathMax(10,InpFontSize+4);
    g_canvas.FontSet("Arial Bold",vol_fs);
    int ly=bar_base-2-vol_fs;
    if(ly>panel_top) g_canvas.TextOut(cx+pw/2,ly,vol_lbl,Argb(0xFFFFFF,255),TA_CENTER|TA_TOP);

    // Bloco delta — ocupa o resto do painel até o timestamp
    int delta_y = bar_base + 1;
    int delta_b = panel_bot;
    if(delta_b > delta_y + 4)
    {
        g_canvas.FillRectangle(cx,delta_y,cx+pw-1,delta_b,
            Argb((c.delta>=0)?0x2563EB:0xF97316,255));
        string ds=(c.delta>=0?"+":"")+IntegerToString((int)c.delta);
        g_canvas.FontSet("Arial Bold",InpFontSize);
        int dh=delta_b-delta_y;
        g_canvas.TextOut(cx+pw/2,delta_y+(dh-InpFontSize)/2,ds,Argb(0xFFFFFF,255),TA_CENTER|TA_TOP);
    }

    // Horário no fundo
    if(c.open_time>0&&g_canvas_h-11>chart_h)
    {
        g_canvas.FontSet("Arial",InpFontSize-1);
        g_canvas.TextOut(cx+2,g_canvas_h-11,
            TimeToString(c.open_time,TIME_MINUTES),Argb(InpColorText,255));
    }
}

//+------------------------------------------------------------------+
//| Menu de Configurações                                             |
//+------------------------------------------------------------------+
#define MNU_X    20
#define MNU_Y    45
#define MNU_W    280
#define MNU_BG   0x0D1220
#define MNU_CARD 0x182032
#define MNU_BTN  0x253348
#define MNU_GRN  0x00C853

void MnuLabel(int y, string txt)
{
    g_canvas.FontSet("Arial Bold",7);
    g_canvas.TextOut(MNU_X+10,y,txt,Argb(0x7A8EA8,255));
}

void MnuToggle(int y, string l, string r, int sel)
{
    int lx=MNU_X+10, mid=MNU_X+MNU_W/2, rx=MNU_X+MNU_W-10, h=30;
    g_canvas.FillRectangle(lx,y,mid,y+h,sel==0?Argb(MNU_BTN,255):Argb(MNU_CARD,255));
    g_canvas.FillRectangle(mid,y,rx,y+h,sel==1?Argb(MNU_BTN,255):Argb(MNU_CARD,255));
    g_canvas.Rectangle(lx,y,rx,y+h,Argb(0x334155,255));
    g_canvas.Line(mid,y,mid,y+h,Argb(0x334155,255));
    g_canvas.FontSet("Arial Bold",9);
    g_canvas.TextOut(lx+(mid-lx)/2-(int)StringLen(l)*5/2,y+9,l,Argb(0xFFFFFF,255));
    g_canvas.TextOut(mid+(rx-mid)/2-(int)StringLen(r)*5/2,y+9,r,Argb(0xFFFFFF,255));
}

void MnuStepper(int y, double val)
{
    int lx=MNU_X+10, rx=MNU_X+MNU_W-10, w=rx-lx;
    g_canvas.FillRectangle(lx,y,rx,y+32,Argb(MNU_CARD,255));
    g_canvas.Rectangle(lx,y,rx,y+32,Argb(0x334155,255));
    g_canvas.FillRectangle(lx+1,y+1,lx+32,y+31,Argb(MNU_BTN,255));
    g_canvas.FillRectangle(rx-32,y+1,rx-1,y+31,Argb(MNU_BTN,255));
    g_canvas.FontSet("Arial Bold",13); g_canvas.TextOut(lx+8,y+5,"−",Argb(0xFFFFFF,255));
    g_canvas.FontSet("Arial Bold",13); g_canvas.TextOut(rx-22,y+5,"+",Argb(0xFFFFFF,255));
    string sv=IntegerToString((int)val);
    g_canvas.FontSet("Arial Bold",10);
    g_canvas.TextOut(lx+w/2-(int)StringLen(sv)*6/2,y+9,sv,Argb(0xFFFFFF,255));
}

void MnuDropdown(int y, string val)
{
    int lx=MNU_X+10, rx=MNU_X+MNU_W-10;
    g_canvas.FillRectangle(lx,y,rx,y+32,Argb(MNU_CARD,255));
    g_canvas.Rectangle(lx,y,rx,y+32,Argb(0x334155,255));
    string cap=val;
    StringSetCharacter(cap,0,(ushort)(StringGetCharacter(cap,0)-32));
    g_canvas.FontSet("Arial",10); g_canvas.TextOut(lx+10,y+9,cap,Argb(0xFFFFFF,255));
    g_canvas.FontSet("Arial",9);  g_canvas.TextOut(rx-18,y+10,"▼",Argb(0x94A3B8,255));
}

void MnuColorRow(int y, string lbl, color c)
{
    int rx=MNU_X+MNU_W-10;
    g_canvas.FontSet("Arial Bold",9); g_canvas.TextOut(MNU_X+10,y+10,lbl,Argb(0xFFFFFF,255));
    string hs=StringFormat("#%02X%02X%02X",(c>>16)&0xFF,(c>>8)&0xFF,c&0xFF);
    g_canvas.FontSet("Arial",8); g_canvas.TextOut(rx-96,y+12,hs,Argb(0x64748B,255));
    g_canvas.FillRectangle(rx-40,y+4,rx-4,y+36,Argb(c,255));
    g_canvas.Rectangle(rx-40,y+4,rx-4,y+36,Argb(0x475569,255));
}

void DrawGearBtn()
{
    uint bg=g_menu_open?Argb(MNU_GRN,255):Argb(0x1E293B,255);
    g_canvas.FillRectangle(5,8,33,36,bg);
    g_canvas.Rectangle(5,8,33,36,Argb(0x334155,255));
    g_canvas.FontSet("Arial",15); g_canvas.TextOut(9,10,"⚙",Argb(0xFFFFFF,255));
}

void DrawMenu()
{
    int tabY=MNU_Y+42, cy=tabY+38;
    int panH=(g_menu_tab==0)?418:255;
    g_canvas.FillRectangle(MNU_X,MNU_Y,MNU_X+MNU_W,MNU_Y+panH,Argb(MNU_BG,255));
    g_canvas.Rectangle(MNU_X,MNU_Y,MNU_X+MNU_W,MNU_Y+panH,Argb(0x2A364F,255));
    // Header
    g_canvas.FillRectangle(MNU_X,MNU_Y,MNU_X+MNU_W,MNU_Y+34,Argb(0x080E18,255));
    g_canvas.FontSet("Arial Bold",11); g_canvas.TextOut(MNU_X+14,MNU_Y+9,"CONFIGURAÇÕES",Argb(0xFFFFFF,255));
    g_canvas.FontSet("Arial Bold",13); g_canvas.TextOut(MNU_X+MNU_W-18,MNU_Y+7,"×",Argb(0x94A3B8,255));
    // Tabs
    int mid=MNU_X+MNU_W/2;
    g_canvas.FillRectangle(MNU_X+10,tabY,mid-2,tabY+30,g_menu_tab==0?Argb(MNU_GRN,255):Argb(MNU_CARD,255));
    g_canvas.FillRectangle(mid+2,tabY,MNU_X+MNU_W-10,tabY+30,g_menu_tab==1?Argb(MNU_GRN,255):Argb(MNU_CARD,255));
    g_canvas.Rectangle(MNU_X+10,tabY,MNU_X+MNU_W-10,tabY+30,Argb(0x334155,255));
    g_canvas.Line(mid,tabY,mid,tabY+30,Argb(0x334155,255));
    g_canvas.FontSet("Arial Bold",9);
    g_canvas.TextOut(MNU_X+30,tabY+9,"Formação",Argb(0xFFFFFF,255));
    g_canvas.TextOut(mid+22,tabY+9,"Cores",Argb(0xFFFFFF,255));
    if(g_menu_tab==0)
    {
        MnuLabel(cy,"MODO DE EXIBIÇÃO"); cy+=16;
        MnuToggle(cy,"Bid x Ask","Delta",g_form_view); cy+=38;
        MnuLabel(cy,"PASSO DO PREÇO (ticks)"); cy+=16;
        MnuStepper(cy,g_form_step); cy+=40;
        MnuLabel(cy,"MODO DE FECHAMENTO"); cy+=16;
        MnuDropdown(cy,g_form_mode); cy+=40;
        MnuLabel(cy,"DELTA MÁX"); cy+=16;
        MnuStepper(cy,g_form_delta); cy+=44;
        bool dirty=(g_form_step!=g_step_mult||g_form_delta!=g_delta_max||g_form_view!=(int)g_view_mode||g_form_mode!=g_close_mode);
        uint abg=dirty?Argb(0x1E40AF,255):Argb(0x1A2234,255);
        g_canvas.FillRectangle(MNU_X+10,cy,MNU_X+MNU_W-10,cy+34,abg);
        g_canvas.Rectangle(MNU_X+10,cy,MNU_X+MNU_W-10,cy+34,Argb(0x334155,255));
        g_canvas.FontSet("Arial Bold",10);
        g_canvas.TextOut(MNU_X+MNU_W/2-22,cy+10,"Aplicar",Argb(dirty?(color)0xFFFFFF:(color)0x475569,255));
    }
    else
    {
        MnuColorRow(cy,"BID (VENDA)",g_color_bid);  cy+=50;
        MnuColorRow(cy,"ASK (COMPRA)",g_color_ask); cy+=50;
        MnuColorRow(cy,"POC (BORDA)",g_color_poc);  cy+=50;
        g_canvas.FontSet("Arial",8);
        g_canvas.TextOut(MNU_X+32,cy+6,"Cores salvas automaticamente",Argb(0x475569,255));
    }
}

void HandleMenuClick(int mx, int my)
{
    // Gear button
    if(mx>=5&&mx<=33&&my>=8&&my<=36)
    {
        g_menu_open=!g_menu_open;
        if(g_menu_open){g_form_step=g_step_mult;g_form_delta=g_delta_max;g_form_view=(int)g_view_mode;g_form_mode=g_close_mode;}
        Redraw(); return;
    }
    if(!g_menu_open) return;
    // X button
    if(mx>=MNU_X+MNU_W-22&&my>=MNU_Y&&my<=MNU_Y+34){g_menu_open=false;Redraw();return;}
    // Tabs
    int tabY=MNU_Y+42, mid=MNU_X+MNU_W/2;
    if(my>=tabY&&my<=tabY+30)
    {
        if(mx>=MNU_X+10&&mx<mid){g_menu_tab=0;Redraw();return;}
        if(mx>=mid&&mx<=MNU_X+MNU_W-10){g_menu_tab=1;Redraw();return;}
    }
    int cy=tabY+38;
    if(g_menu_tab==0)
    {
        cy+=16;
        if(my>=cy&&my<=cy+30){if(mx<mid)g_form_view=0;else g_form_view=1;Redraw();return;}
        cy+=38+16;
        if(my>=cy&&my<=cy+32){if(mx<=MNU_X+42)g_form_step=MathMax(1,g_form_step-50);else if(mx>=MNU_X+MNU_W-42)g_form_step+=50;Redraw();return;}
        cy+=40+16;
        if(my>=cy&&my<=cy+32){if(g_form_mode=="delta")g_form_mode="volume";else if(g_form_mode=="volume")g_form_mode="range";else if(g_form_mode=="range")g_form_mode="time";else g_form_mode="delta";Redraw();return;}
        cy+=40+16;
        if(my>=cy&&my<=cy+32){if(mx<=MNU_X+42)g_form_delta=MathMax(200,g_form_delta-200);else if(mx>=MNU_X+MNU_W-42)g_form_delta+=200;Redraw();return;}
        cy+=44;
        if(my>=cy&&my<=cy+34&&mx>=MNU_X+10&&mx<=MNU_X+MNU_W-10)
        {
            g_step_mult=g_form_step; g_delta_max=g_form_delta;
            g_view_mode=(ENUM_VIEW)g_form_view; g_close_mode=g_form_mode;
            Reload(); return;
        }
    }
    else
    {
        int rx=MNU_X+MNU_W-10;
        if(my>=cy+4&&my<=cy+36&&mx>=rx-40&&mx<=rx-4){ OpenColorPicker(PICK_GLOBAL_BID, rx-40, cy+36); return; }
        cy+=50;
        if(my>=cy+4&&my<=cy+36&&mx>=rx-40&&mx<=rx-4){ OpenColorPicker(PICK_GLOBAL_ASK, rx-40, cy+36); return; }
        cy+=50;
        if(my>=cy+4&&my<=cy+36&&mx>=rx-40&&mx<=rx-4){ OpenColorPicker(PICK_GLOBAL_POC, rx-40, cy+36); return; }
    }
}

//+------------------------------------------------------------------+
//| Eixo de preço                                                     |
//+------------------------------------------------------------------+
void DrawPriceAxis(int x0, int chart_h, double pmin, double pmax)
{
    double prange=pmax-pmin; if(prange<=0) return;
    g_canvas.FillRectangle(x0,0,g_canvas_w-1,chart_h,Argb(InpColorBg,255));
    g_canvas.Line(x0,0,x0,chart_h,Argb(0x2A364F,255));
    double step=g_step*10,nL=prange/step;
    if(nL>20) step*=MathCeil(nL/20.0);
    for(double p=MathCeil(pmin/step)*step;p<=pmax;p+=step)
    {
        int y=chart_h-1-(int)((p-pmin)/prange*(chart_h-4));
        if(y<5||y>chart_h-5) continue;
        g_canvas.Line(x0,y,x0+4,y,Argb(0x475569,255));
        TxtOut(x0+7,y-5,DoubleToString(p,_Digits),Argb(0x64748B,255),"Arial",InpFontSize);
    }
}

//+------------------------------------------------------------------+
//| Conversores pixel ↔ preço/cluster (usam estado do último Redraw) |
//+------------------------------------------------------------------+
int PriceToY(double price)
{
    if(g_rdr_chart_h<=0||g_rdr_pmax<=g_rdr_pmin) return 0;
    return g_rdr_chart_h-1-(int)((price-g_rdr_pmin)/(g_rdr_pmax-g_rdr_pmin)*(g_rdr_chart_h-4));
}
double YToPrice(int y)
{
    if(g_rdr_chart_h<=0||g_rdr_pmax<=g_rdr_pmin) return 0;
    return g_rdr_pmin+(double)(g_rdr_chart_h-1-y)*(g_rdr_pmax-g_rdr_pmin)/(g_rdr_chart_h-4);
}
// X canvas → índice absoluto do cluster no histórico
int XToClusterIdx(int x)
{
    if(g_rdr_col_step<=0) return 0;
    int ref_x=g_rdr_chart_x1-g_rdr_col_step*(3+g_rdr_active_off)-g_rdr_cw;
    int steps=(ref_x-x)/g_rdr_col_step;
    if(steps<0) steps=0;
    return MathMax(0,MathMin(g_history_count-1, g_rdr_last_idx-steps));
}
// Índice absoluto → X esquerdo do cluster no canvas (-1 = fora da área)
int ClusterToX(int ci)
{
    if(g_rdr_col_step<=0) return -1;
    int steps=g_rdr_last_idx-ci;
    if(steps<0) return -1;
    return g_rdr_chart_x1-g_rdr_col_step*(3+g_rdr_active_off+steps)-g_rdr_cw;
}

//+------------------------------------------------------------------+
//| Zona — fill antes dos clusters, borda depois                     |
//+------------------------------------------------------------------+
void DrawZoneFills(int chart_h, double pmin, double pmax)
{
    for(int zi=0;zi<g_zone_count;zi++)
    {
        if(!g_zones[zi].active) continue;
        if(g_zones[zi].sobre_clusters) continue;  // será desenhado após os clusters
        // ci_from = older (menor índice) = lado ESQUERDO (X menor)
        // ci_to   = newer (maior índice) = lado DIREITO  (X maior)
        int x1=ClusterToX(g_zones[zi].ci_from);
        int x2=ClusterToX(g_zones[zi].ci_to)+g_rdr_cw;
        if(g_zones[zi].raio_dir) x2=g_rdr_chart_x1;
        if(g_zones[zi].raio_esq) x1=0;
        if(x1<0) x1=0;
        if(x2<=x1||x2<0) continue;
        double prange=pmax-pmin;
        int y1=chart_h-1-(int)((g_zones[zi].price_high-pmin)/prange*(chart_h-4));
        int y2=chart_h-1-(int)((g_zones[zi].price_low -pmin)/prange*(chart_h-4));
        if(y1>y2){int t=y1;y1=y2;y2=t;}
        y1=MathMax(0,y1); y2=MathMin(chart_h-1,y2);
        uint fill=Blend(g_zones[zi].border_clr,(color)InpColorBg,0.10);
        g_canvas.FillRectangle(x1,y1,x2,y2,0xFF000000|fill);
    }
}
void DrawZoneBorders(int chart_h, double pmin, double pmax)
{
    for(int zi=0;zi<g_zone_count;zi++)
    {
        if(!g_zones[zi].active) continue;
        int x1=ClusterToX(g_zones[zi].ci_from);
        int x2=ClusterToX(g_zones[zi].ci_to)+g_rdr_cw;
        if(g_zones[zi].raio_dir) x2=g_rdr_chart_x1;
        if(g_zones[zi].raio_esq) x1=0;
        if(x1<0) x1=0;
        if(x2<=x1) continue;
        double prange=pmax-pmin;
        int y1=chart_h-1-(int)((g_zones[zi].price_high-pmin)/prange*(chart_h-4));
        int y2=chart_h-1-(int)((g_zones[zi].price_low -pmin)/prange*(chart_h-4));
        if(y1>y2){int t=y1;y1=y2;y2=t;}
        y1=MathMax(0,y1); y2=MathMin(chart_h-1,y2);
        if(g_zones[zi].sobre_clusters)
        {
            uint fill=Blend(g_zones[zi].border_clr,(color)InpColorBg,0.25);
            g_canvas.FillRectangle(x1,y1,x2,y2,0xFF000000|fill);
        }
        // Destacar zona selecionada
        if(g_zone_panel && zi==g_zone_sel)
            g_canvas.Rectangle(x1-1,y1-1,x2+1,y2+1,Argb(0xFFFFFF,255));
        g_canvas.Rectangle(x1,y1,x2,y2,Argb(g_zones[zi].border_clr,255));
    }
}

//+------------------------------------------------------------------+
//| Volume Profile — desenhado sobre os clusters                     |
//+------------------------------------------------------------------+
void CalcVProfile(SVProfile &vp, int ci_from, int ci_to,
                  double price_high, double price_low)
{
    vp.ci_from=ci_from; vp.ci_to=ci_to;
    vp.price_high=price_high; vp.price_low=price_low;
    vp.show_volume=true; vp.show_delta=false; vp.delta_espelhado=true; vp.volume_soma=false;
    vp.show_poc=true; vp.show_va=true; vp.va_pct=70.0; vp.show_vwap=false;
    vp.sobre_clusters=false;
    vp.clr_bid=g_color_bid; vp.clr_ask=g_color_ask; vp.clr_poc=(color)0xFFD600;
    vp.clr_borda=(color)0x2A364F; vp.count=0;
    ArrayInitialize(vp.prices,0); ArrayInitialize(vp.vol_bid,0); ArrayInitialize(vp.vol_ask,0);

    double cum_pv=0, cum_v=0;
    // Percorre clusters na faixa
    for(int ci=ci_from;ci<=ci_to&&ci<g_history_count;ci++)
    {
        int hi=HIdx(ci);
        for(int li=0;li<g_history[hi].level_count;li++)
        {
            double p=g_history[hi].levels[li].price;
            if(p<price_low-g_step||p>price_high+g_step) continue;
            double bin=MathRound(p/g_step)*g_step;
            int idx=-1;
            for(int k=0;k<vp.count;k++) if(MathAbs(vp.prices[k]-bin)<1e-8){idx=k;break;}
            if(idx<0)
            {
                if(vp.count>=VP_LEVELS) continue;
                idx=vp.count++;
                vp.prices[idx]=bin; vp.vol_bid[idx]=0; vp.vol_ask[idx]=0;
            }
            vp.vol_bid[idx]+=g_history[hi].levels[li].bid;
            vp.vol_ask[idx]+=g_history[hi].levels[li].ask;
            double vol=g_history[hi].levels[li].bid+g_history[hi].levels[li].ask;
            cum_pv+=bin*vol; cum_v+=vol;
        }
    }
    vp.vwap_price=(cum_v>0)?cum_pv/cum_v:0;

    // POC — nível com maior volume total
    double mx=-1; vp.poc_price=0;
    double total_vol=0;
    for(int i=0;i<vp.count;i++)
    {
        double t=vp.vol_bid[i]+vp.vol_ask[i];
        if(t>mx){mx=t;vp.poc_price=vp.prices[i];}
        total_vol+=t;
    }

    // VAH/VAL — expansão 70% a partir do POC
    vp.vah_price=vp.poc_price; vp.val_price=vp.poc_price;
    if(total_vol>0&&mx>0)
    {
        double poc_vol=0;
        for(int i=0;i<vp.count;i++) if(MathAbs(vp.prices[i]-vp.poc_price)<1e-8){poc_vol=vp.vol_bid[i]+vp.vol_ask[i];break;}
        double cum=poc_vol, target=total_vol*(vp.va_pct/100.0);
        double up=vp.poc_price+g_step, lo=vp.poc_price-g_step;
        while(cum<target)
        {
            double up_v=0,lo_v=0;
            for(int i=0;i<vp.count;i++)
            {
                if(MathAbs(vp.prices[i]-up)<1e-8) up_v=vp.vol_bid[i]+vp.vol_ask[i];
                if(MathAbs(vp.prices[i]-lo)<1e-8) lo_v=vp.vol_bid[i]+vp.vol_ask[i];
            }
            if(up_v<=0&&lo_v<=0) break;
            if(up_v>=lo_v){cum+=up_v;vp.vah_price=up;up+=g_step;}
            else           {cum+=lo_v;vp.val_price=lo;lo-=g_step;}
        }
    }
    vp.active=true;
}

// VA overlay: retângulo semi-transparente sobre TODA a largura do gráfico
// Deve ser chamado ANTES dos clusters
void DrawVAOverlays(int chart_h, double pmin, double pmax)
{
    double prange=pmax-pmin;
    for(int vi=0;vi<g_vp_count;vi++)
    {
        if(!g_vprofiles[vi].active||!g_vprofiles[vi].show_va||g_vprofiles[vi].poc_price<=0) continue;
        int vah_y=chart_h-1-(int)((g_vprofiles[vi].vah_price-pmin)/prange*(chart_h-4));
        int val_y=chart_h-1-(int)((g_vprofiles[vi].val_price-pmin)/prange*(chart_h-4));
        if(vah_y>val_y){int t=vah_y;vah_y=val_y;val_y=t;}
        vah_y=MathMax(0,vah_y); val_y=MathMin(chart_h-1,val_y);
        uint fill=Blend(g_vprofiles[vi].clr_ask,(color)InpColorBg,0.14);
        g_canvas.FillRectangle(0,vah_y,g_rdr_chart_x1,val_y,fill);
    }
}

// behind=true → desenha VPs que ficam ATRÁS dos clusters (sobre_clusters=false)
// behind=false → desenha VPs que ficam NA FRENTE dos clusters (sobre_clusters=true)
void DrawVProfiles(int chart_h, double pmin, double pmax, bool behind)
{
    int cw = g_rdr_chart_x1;  // largura total do gráfico (para linhas full-width)

    for(int vi=0;vi<g_vp_count;vi++)
    {
        if(!g_vprofiles[vi].active||g_vprofiles[vi].count<=0) continue;
        // Filtro de passe: sobre_clusters==behind significa que é o passe errado
        if(g_vprofiles[vi].sobre_clusters==behind) continue;

        int x1=ClusterToX(g_vprofiles[vi].ci_from);
        int x2=ClusterToX(g_vprofiles[vi].ci_to)+g_rdr_cw;
        if(x1<0) x1=0;
        if(x2<=x1) continue;

        // Painel do histograma: largura máxima 140px a partir de x1
        int bar_max=MathMin(140, x2-x1);
        int bx1=x1, bx2=x1+bar_max;

        color fundo=(color)0x080C16;
        g_canvas.FillRectangle(bx1,0,bx2,chart_h,Argb(fundo,255));
        if(g_vp_panel&&vi==g_vp_sel)
            g_canvas.Rectangle(bx1-1,0,bx2+1,chart_h-1,Argb(0xFFFFFF,255));
        g_canvas.Rectangle(bx1,0,bx2,chart_h-1,Argb(g_vprofiles[vi].clr_borda,255));

        double max_vol=1;
        for(int i=0;i<g_vprofiles[vi].count;i++){double t=g_vprofiles[vi].vol_bid[i]+g_vprofiles[vi].vol_ask[i];if(t>max_vol)max_vol=t;}
        double max_delta=1;
        for(int i=0;i<g_vprofiles[vi].count;i++){double d=MathAbs(g_vprofiles[vi].vol_ask[i]-g_vprofiles[vi].vol_bid[i]);if(d>max_delta)max_delta=d;}

        double prange=pmax-pmin;
        color clr_bid=g_vprofiles[vi].clr_bid;
        color clr_ask=g_vprofiles[vi].clr_ask;

        for(int i=0;i<g_vprofiles[vi].count;i++)
        {
            double price=g_vprofiles[vi].prices[i];
            int yt=chart_h-1-(int)((price+g_step*0.5-pmin)/prange*(chart_h-4));
            int yb=chart_h-1-(int)((price-g_step*0.5-pmin)/prange*(chart_h-4));
            if(yt>yb){int t=yt;yt=yb;yb=t;}
            if(yb<0||yt>chart_h) continue;
            yt=MathMax(0,yt); yb=MathMin(chart_h-1,yb);

            bool in_va=(g_vprofiles[vi].show_va&&price>=g_vprofiles[vi].val_price&&price<=g_vprofiles[vi].vah_price);
            double alpha_out=0.30;

            if(g_vprofiles[vi].show_volume)
            {
                double total=g_vprofiles[vi].vol_bid[i]+g_vprofiles[vi].vol_ask[i];
                int bw=(int)(total/max_vol*(bar_max-2));
                if(bw<1&&total>0) bw=1;
                if(g_vprofiles[vi].volume_soma)
                {
                    uint c=in_va?Argb(clr_ask,255):Blend(clr_ask,fundo,alpha_out);
                    if(bw>0) g_canvas.FillRectangle(bx1+1,yt,bx1+bw,yb,c);
                }
                else
                {
                    int bw_bid=(total>0)?(int)(g_vprofiles[vi].vol_bid[i]/total*bw):0;
                    int bw_ask=bw-bw_bid;
                    uint c_bid=in_va?Argb(clr_bid,255):Blend(clr_bid,fundo,alpha_out);
                    uint c_ask=in_va?Argb(clr_ask,255):Blend(clr_ask,fundo,alpha_out);
                    if(bw_bid>0) g_canvas.FillRectangle(bx1+1,yt,bx1+bw_bid,yb,c_bid);
                    if(bw_ask>0) g_canvas.FillRectangle(bx1+1+bw_bid,yt,bx1+bw,yb,c_ask);
                }
            }

            if(g_vprofiles[vi].show_delta)
            {
                double delta=g_vprofiles[vi].vol_ask[i]-g_vprofiles[vi].vol_bid[i];
                int bw=(int)(MathAbs(delta)/max_delta*(bar_max/2-2));
                if(bw<1&&delta!=0) bw=1;
                bool pos=(delta>=0);
                uint c=pos?(in_va?Argb(clr_ask,255):Blend(clr_ask,fundo,alpha_out))
                          :(in_va?Argb(clr_bid,255):Blend(clr_bid,fundo,alpha_out));
                int cx_delta=bx1+bar_max/2;
                if(g_vprofiles[vi].delta_espelhado)
                {
                    if(pos) g_canvas.FillRectangle(cx_delta,yt,cx_delta+bw,yb,c);
                    else    g_canvas.FillRectangle(cx_delta-bw,yt,cx_delta,yb,c);
                }
                else    g_canvas.FillRectangle(bx1+1,yt,bx1+bw,yb,c);
            }
        }

        // POC — linha no painel + linha pontilhada por todo o gráfico
        if(g_vprofiles[vi].show_poc&&g_vprofiles[vi].poc_price>0)
        {
            int poc_y=chart_h-1-(int)((g_vprofiles[vi].poc_price-pmin)/prange*(chart_h-4));
            if(poc_y>=0&&poc_y<chart_h)
            {
                for(int xx=bx1;xx<=bx2;xx++) g_canvas.PixelSet(xx,poc_y,Argb(g_vprofiles[vi].clr_poc,255));
                for(int xx=bx2;xx<cw;xx++) g_canvas.PixelSet(xx,poc_y,Argb(g_vprofiles[vi].clr_poc,255));
            }
        }
        // VAH/VAL — linhas pontilhadas por todo o gráfico
        if(g_vprofiles[vi].show_va&&g_vprofiles[vi].poc_price>0)
        {
            int vah_y=chart_h-1-(int)((g_vprofiles[vi].vah_price-pmin)/prange*(chart_h-4));
            for(int xx=0;xx<cw;xx+=8) g_canvas.Line(xx,vah_y,MathMin(xx+4,cw),vah_y,Argb(0x94A3B8,255));
            int val_y=chart_h-1-(int)((g_vprofiles[vi].val_price-pmin)/prange*(chart_h-4));
            for(int xx=0;xx<cw;xx+=8) g_canvas.Line(xx,val_y,MathMin(xx+4,cw),val_y,Argb(0x94A3B8,255));
        }
        // VWAP — linha pontilhada por todo o gráfico
        if(g_vprofiles[vi].show_vwap&&g_vprofiles[vi].vwap_price>0)
        {
            int vy=chart_h-1-(int)((g_vprofiles[vi].vwap_price-pmin)/prange*(chart_h-4));
            if(vy>=0&&vy<chart_h)
                for(int xx=bx2;xx<cw;xx+=8) g_canvas.Line(xx,vy,MathMin(xx+5,cw),vy,Argb(0xFF4081,255));
        }
    }
}

//+------------------------------------------------------------------+
//| Painel de configuração de zona                                   |
//+------------------------------------------------------------------+
void ZonePanelPos(int &px, int &py)
{
    int pw=244, ph=205;
    px=g_zpx; py=g_zpy;
    if(px+pw>g_canvas_w) px=g_canvas_w-pw-4;
    if(py+ph>g_canvas_h) py=g_canvas_h-ph-4;
    if(px<0) px=4;
    if(py<0) py=4;
}

void DrawZoneCheck(int x, int y, bool val, string lbl)
{
    g_canvas.Rectangle(x,y,x+12,y+12,Argb(0x475569,255));
    if(val)
    {
        g_canvas.Line(x+2,y+7,x+5,y+11,Argb(0x22C55E,255));
        g_canvas.Line(x+5,y+11,x+10,y+3,Argb(0x22C55E,255));
    }
    g_canvas.FontSet("Arial",9);
    g_canvas.TextOut(x+16,y,lbl,Argb(0xCBD5E1,255),TA_LEFT|TA_TOP);
}

void DrawZonePanel()
{
    if(!g_zone_panel||g_zone_sel<0||g_zone_sel>=g_zone_count) return;
    int pw=244, ph=205;
    int px, py; ZonePanelPos(px,py);

    g_canvas.FillRectangle(px,py,px+pw,py+ph,Argb(0x0F1520,255));
    g_canvas.Rectangle(px,py,px+pw,py+ph,Argb(0x2A364F,255));

    // Header
    g_canvas.FillRectangle(px,py,px+pw,py+30,Argb(0x080E18,255));
    g_canvas.FontSet("Arial Bold",10);
    g_canvas.TextOut(px+10,py+8,StringFormat("Zona #%d",g_zone_sel+1),Argb(0xFF4081,255),TA_LEFT|TA_TOP);
    g_canvas.FontSet("Arial Bold",14);
    g_canvas.TextOut(px+pw-18,py+5,"×",Argb(0x94A3B8,255),TA_LEFT|TA_TOP);

    // Info preço
    int cy=py+36; int lx=px+10; int vx=px+118;
    g_canvas.FontSet("Arial",9);
    g_canvas.TextOut(lx,cy,"Preço alto:",Argb(0x64748B,255),TA_LEFT|TA_TOP);
    g_canvas.TextOut(vx,cy,DoubleToString(g_zones[g_zone_sel].price_high,2),Argb(0xE2E8F0,255),TA_LEFT|TA_TOP);
    cy+=18;
    g_canvas.TextOut(lx,cy,"Preço baixo:",Argb(0x64748B,255),TA_LEFT|TA_TOP);
    g_canvas.TextOut(vx,cy,DoubleToString(g_zones[g_zone_sel].price_low,2),Argb(0xE2E8F0,255),TA_LEFT|TA_TOP);
    cy+=22;

    // Separador
    g_canvas.Line(px+4,cy,px+pw-4,cy,Argb(0x1E293B,255));
    cy+=8;

    // Cor borda
    g_canvas.TextOut(lx,cy,"Cor borda:",Argb(0x64748B,255),TA_LEFT|TA_TOP);
    color bc=g_zones[g_zone_sel].border_clr;
    g_canvas.FillRectangle(vx,cy,vx+32,cy+14,Argb(bc,255));
    g_canvas.Rectangle(vx,cy,vx+32,cy+14,Argb(0x475569,255));
    g_canvas.FontSet("Arial",8);
    g_canvas.TextOut(vx+36,cy+2,"← clique",Argb(0x475569,255),TA_LEFT|TA_TOP);
    cy+=24;

    // Separador
    g_canvas.Line(px+4,cy,px+pw-4,cy,Argb(0x1E293B,255));
    cy+=8;

    // Checkboxes
    DrawZoneCheck(lx,cy,g_zones[g_zone_sel].raio_esq,"Raio esquerdo");
    DrawZoneCheck(px+130,cy,g_zones[g_zone_sel].raio_dir,"Raio direito");
    cy+=22;
    DrawZoneCheck(px+130,cy,g_zones[g_zone_sel].sobre_clusters,"Sobre os clusters");
    cy+=26;

    // Separador
    g_canvas.Line(px+4,cy,px+pw-4,cy,Argb(0x1E293B,255));
    cy+=8;

    // Botão excluir
    g_canvas.FillRectangle(px+10,cy,px+pw-10,cy+24,Argb(0x7F1D1D,255));
    g_canvas.Rectangle(px+10,cy,px+pw-10,cy+24,Argb(0xEF4444,255));
    g_canvas.FontSet("Arial Bold",9);
    g_canvas.TextOut(px+pw/2,cy+6,"Excluir zona",Argb(0xFFFFFF,255),TA_CENTER|TA_TOP);
}

int HitTestZone(int mx, int my)
{
    if(g_rdr_col_step<=0) return -1;
    int chart_h=g_canvas_h-InpBottomPanel;
    if(my<0||my>=chart_h) return -1;
    for(int zi=0;zi<g_zone_count;zi++)
    {
        if(!g_zones[zi].active) continue;
        int x1=ClusterToX(g_zones[zi].ci_from);
        int x2=ClusterToX(g_zones[zi].ci_to)+g_rdr_cw;
        if(g_zones[zi].raio_dir) x2=g_rdr_chart_x1;
        if(g_zones[zi].raio_esq) x1=0;
        if(x1<0) x1=0;
        if(mx<x1||mx>x2) continue;
        int y1=PriceToY(g_zones[zi].price_high);
        int y2=PriceToY(g_zones[zi].price_low);
        if(y1>y2){int t=y1;y1=y2;y2=t;}
        if(my>=y1&&my<=y2) return zi;
    }
    return -1;
}

void DrawColorPicker()
{
    int px=g_pick_px, py=g_pick_py;
    g_canvas.FillRectangle(px,py,px+PICK_W,py+PICK_H,Argb(0x0F1520,255));
    g_canvas.Rectangle(px,py,px+PICK_W,py+PICK_H,Argb(0x475569,255));
    g_canvas.FillRectangle(px,py,px+PICK_W,py+30,Argb(0x080E18,255));
    g_canvas.FontSet("Arial Bold",9);
    g_canvas.TextOut(px+8,py+9,"Selecionar Cor",Argb(0xE2E8F0,255),TA_LEFT|TA_TOP);
    g_canvas.TextOut(px+PICK_W-18,py+8,"✕",Argb(0xEF4444,255),TA_LEFT|TA_TOP);
    g_canvas.Line(px,py+30,px+PICK_W,py+30,Argb(0x2A364F,255));
    int n=ArraySize(g_pick_palette);
    for(int r=0;r<PICK_ROWS;r++)
        for(int c=0;c<PICK_COLS;c++)
        {
            int idx=r*PICK_COLS+c; if(idx>=n) break;
            int sx=px+PICK_PAD+c*(PICK_SW+PICK_GAP);
            int sy=py+32+PICK_PAD/2+r*(PICK_SH+PICK_GAP);
            g_canvas.FillRectangle(sx,sy,sx+PICK_SW-1,sy+PICK_SH-1,Argb(g_pick_palette[idx],255));
            g_canvas.Rectangle(sx,sy,sx+PICK_SW-1,sy+PICK_SH-1,Argb(0x2A364F,255));
        }
}

void ApplyPickedColor(color c)
{
    switch(g_pick_target)
    {
        case PICK_ZONE_BORDER:  if(g_zone_sel>=0) g_zones[g_zone_sel].border_clr=c; break;
        case PICK_VP_BID:       if(g_vp_sel>=0)   g_vprofiles[g_vp_sel].clr_bid=c; break;
        case PICK_VP_ASK:       if(g_vp_sel>=0)   g_vprofiles[g_vp_sel].clr_ask=c; break;
        case PICK_VP_POC:       if(g_vp_sel>=0)   g_vprofiles[g_vp_sel].clr_poc=c; break;
        case PICK_GLOBAL_BID:   g_color_bid=c; break;
        case PICK_GLOBAL_ASK:   g_color_ask=c; break;
        case PICK_GLOBAL_POC:   g_color_poc=c; break;
        default: break;
    }
}

void HandleColorPickerClick(int mx, int my)
{
    int px=g_pick_px, py=g_pick_py;
    if(mx>=px+PICK_W-22&&my>=py&&my<=py+30){ g_pick_open=false; Redraw(); return; }
    int gx=mx-(px+PICK_PAD);
    int gy=my-(py+32+PICK_PAD/2);
    if(gx<0||gy<0) return;
    int col=gx/(PICK_SW+PICK_GAP), row=gy/(PICK_SH+PICK_GAP);
    if(col<0||col>=PICK_COLS||row<0||row>=PICK_ROWS) return;
    if(gx%(PICK_SW+PICK_GAP)>=PICK_SW||gy%(PICK_SH+PICK_GAP)>=PICK_SH) return;
    int idx=row*PICK_COLS+col;
    if(idx>=ArraySize(g_pick_palette)) return;
    ApplyPickedColor(g_pick_palette[idx]);
    g_pick_open=false;
    Redraw();
}

void OpenColorPicker(EPICK_TARGET target, int near_x, int near_y)
{
    g_pick_target=target;
    g_pick_px=near_x; g_pick_py=near_y;
    if(g_pick_px+PICK_W>g_canvas_w) g_pick_px=g_canvas_w-PICK_W-4;
    if(g_pick_py+PICK_H>g_canvas_h) g_pick_py=g_canvas_h-PICK_H-4;
    if(g_pick_px<0) g_pick_px=4;
    if(g_pick_py<0) g_pick_py=4;
    g_pick_open=true;
    Redraw();
}

void HandleZonePanelClick(int mx, int my)
{
    if(g_zone_sel<0||g_zone_sel>=g_zone_count) return;
    int pw=244, ph=205;
    int px, py; ZonePanelPos(px,py);

    // Botão ✕ fechar
    if(mx>=px+pw-22&&my>=py&&my<=py+30)
    { g_zone_panel=false; g_zone_sel=-1; Redraw(); return; }

    int cy=py+36+18+22+8;   // posição após preços e separador = py+84
    // Cor borda swatch (vx=px+118, cy..cy+14)
    if(mx>=px+118&&mx<=px+150&&my>=cy&&my<=cy+14)
    { OpenColorPicker(PICK_ZONE_BORDER, px+118, cy+16); return; }
    cy+=24+8;   // cy = py+116: checkboxes row 1

    // Raio esquerdo (px+10, cy)
    if(mx>=px+10&&mx<=px+22&&my>=cy&&my<=cy+12)
    { g_zones[g_zone_sel].raio_esq=!g_zones[g_zone_sel].raio_esq; Redraw(); return; }
    // Raio direito (px+130, cy)
    if(mx>=px+130&&mx<=px+142&&my>=cy&&my<=cy+12)
    { g_zones[g_zone_sel].raio_dir=!g_zones[g_zone_sel].raio_dir; Redraw(); return; }
    cy+=22;     // cy = py+138: checkboxes row 2

    // Sobre os clusters (px+130, cy)
    if(mx>=px+130&&mx<=px+142&&my>=cy&&my<=cy+12)
    { g_zones[g_zone_sel].sobre_clusters=!g_zones[g_zone_sel].sobre_clusters; Redraw(); return; }
    cy+=26+8;   // cy = py+172: excluir button

    // Botão excluir
    if(mx>=px+10&&mx<=px+pw-10&&my>=cy&&my<=cy+24)
    {
        for(int i=g_zone_sel;i<g_zone_count-1;i++) g_zones[i]=g_zones[i+1];
        g_zone_count--;
        g_zone_panel=false; g_zone_sel=-1; Redraw(); return;
    }
}

//+------------------------------------------------------------------+
//| Painel de configuração de VP                                     |
//+------------------------------------------------------------------+
void VPPanelPos(int &px, int &py)
{
    int pw=290, ph=280;
    px=g_vppx; py=g_vppy;
    if(px+pw>g_canvas_w) px=g_canvas_w-pw-4;
    if(py+ph>g_canvas_h) py=g_canvas_h-ph-4;
    if(px<0) px=4;
    if(py<0) py=4;
}

void DrawVPCheck(int x, int y, bool val, string lbl)
{
    g_canvas.Rectangle(x,y,x+12,y+12,Argb(0x475569,255));
    if(val){g_canvas.Line(x+2,y+7,x+5,y+11,Argb(0x22C55E,255));g_canvas.Line(x+5,y+11,x+10,y+3,Argb(0x22C55E,255));}
    g_canvas.FontSet("Arial",9);
    g_canvas.TextOut(x+16,y,lbl,Argb(0xCBD5E1,255),TA_LEFT|TA_TOP);
}

void DrawVPSwatch(int x, int y, color c, string lbl)
{
    g_canvas.FontSet("Arial",8);
    g_canvas.TextOut(x,y,lbl,Argb(0x64748B,255),TA_LEFT|TA_TOP);
    g_canvas.FillRectangle(x,y+12,x+28,y+26,Argb(c,255));
    g_canvas.Rectangle(x,y+12,x+28,y+26,Argb(0x475569,255));
}

void DrawVPPanel()
{
    if(!g_vp_panel||g_vp_sel<0||g_vp_sel>=g_vp_count) return;
    int pw=290, ph=280;
    int px, py; VPPanelPos(px,py);

    g_canvas.FillRectangle(px,py,px+pw,py+ph,Argb(0x0F1520,255));
    g_canvas.Rectangle(px,py,px+pw,py+ph,Argb(0x2A364F,255));

    // Header
    g_canvas.FillRectangle(px,py,px+pw,py+30,Argb(0x080E18,255));
    g_canvas.FontSet("Arial Bold",10);
    g_canvas.TextOut(px+10,py+8,StringFormat("VP #%d",g_vp_sel+1),Argb(0x22C55E,255),TA_LEFT|TA_TOP);
    g_canvas.FontSet("Arial Bold",14);
    g_canvas.TextOut(px+pw-18,py+5,"×",Argb(0x94A3B8,255),TA_LEFT|TA_TOP);

    int cy=py+36; int lx=px+10;

    // Linha: Visualizar — botões Volume / Delta
    g_canvas.FontSet("Arial",9);
    g_canvas.TextOut(lx,cy,"Visualizar:",Argb(0x64748B,255),TA_LEFT|TA_TOP);
    bool sv=g_vprofiles[g_vp_sel].show_volume;
    bool sd=g_vprofiles[g_vp_sel].show_delta;
    uint vol_bg=sv?Argb(0x1E40AF,255):Argb(0x1A2234,255);
    uint del_bg=sd?Argb(0x065F46,255):Argb(0x1A2234,255);
    g_canvas.FillRectangle(px+90,cy-1,px+140,cy+14,vol_bg);
    g_canvas.Rectangle(px+90,cy-1,px+140,cy+14,Argb(0x334155,255));
    g_canvas.TextOut(px+100,cy,"Volume",sv?Argb(0xFFFFFF,255):Argb(0x64748B,255),TA_LEFT|TA_TOP);
    g_canvas.FillRectangle(px+144,cy-1,px+192,cy+14,del_bg);
    g_canvas.Rectangle(px+144,cy-1,px+192,cy+14,Argb(0x334155,255));
    g_canvas.TextOut(px+154,cy,"Delta",sd?Argb(0xFFFFFF,255):Argb(0x64748B,255),TA_LEFT|TA_TOP);
    cy+=22;

    // Separador
    g_canvas.Line(px+4,cy,px+pw-4,cy,Argb(0x1E293B,255)); cy+=6;

    // Cores das barras
    DrawVPSwatch(lx,      cy,g_vprofiles[g_vp_sel].clr_bid,"Bid");
    DrawVPSwatch(lx+50,   cy,g_vprofiles[g_vp_sel].clr_ask,"Ask");
    DrawVPSwatch(lx+100,  cy,g_vprofiles[g_vp_sel].clr_poc,"POC");
    cy+=34;

    // Checkboxes linha 1
    DrawVPCheck(lx,     cy,g_vprofiles[g_vp_sel].volume_soma,    "Soma");
    DrawVPCheck(lx+80,  cy,g_vprofiles[g_vp_sel].delta_espelhado,"Espelhado");
    DrawVPCheck(lx+188, cy,g_vprofiles[g_vp_sel].sobre_clusters, "S/ clusters");
    cy+=22;

    // Separador
    g_canvas.Line(px+4,cy,px+pw-4,cy,Argb(0x1E293B,255)); cy+=6;

    // POC + VA
    DrawVPCheck(lx,    cy,g_vprofiles[g_vp_sel].show_poc, "POC");
    DrawVPCheck(lx+60, cy,g_vprofiles[g_vp_sel].show_va,  "VA");
    // VA% stepper
    g_canvas.FontSet("Arial",9);
    g_canvas.TextOut(lx+130,cy,StringFormat("%.0f%%",g_vprofiles[g_vp_sel].va_pct),Argb(0xE2E8F0,255),TA_LEFT|TA_TOP);
    g_canvas.FillRectangle(lx+152,cy,lx+164,cy+12,Argb(0x1A2234,255));
    g_canvas.Rectangle(lx+152,cy,lx+164,cy+12,Argb(0x334155,255));
    g_canvas.TextOut(lx+154,cy+1,"–",Argb(0xF59E0B,255),TA_LEFT|TA_TOP);
    g_canvas.FillRectangle(lx+166,cy,lx+178,cy+12,Argb(0x1A2234,255));
    g_canvas.Rectangle(lx+166,cy,lx+178,cy+12,Argb(0x334155,255));
    g_canvas.TextOut(lx+168,cy+1,"+",Argb(0x22C55E,255),TA_LEFT|TA_TOP);
    cy+=22;

    // VWAP
    DrawVPCheck(lx,cy,g_vprofiles[g_vp_sel].show_vwap,"VWAP");
    cy+=22;

    // Separador
    g_canvas.Line(px+4,cy,px+pw-4,cy,Argb(0x1E293B,255)); cy+=8;

    // Botão excluir
    g_canvas.FillRectangle(px+10,cy,px+pw-10,cy+24,Argb(0x7F1D1D,255));
    g_canvas.Rectangle(px+10,cy,px+pw-10,cy+24,Argb(0xEF4444,255));
    g_canvas.FontSet("Arial Bold",9);
    g_canvas.TextOut(px+pw/2,cy+6,"Excluir VP",Argb(0xFFFFFF,255),TA_CENTER|TA_TOP);
}

int HitTestVP(int mx, int my)
{
    if(g_rdr_col_step<=0) return -1;
    int chart_h=g_canvas_h-InpBottomPanel;
    if(my<0||my>=chart_h) return -1;
    for(int vi=0;vi<g_vp_count;vi++)
    {
        if(!g_vprofiles[vi].active) continue;
        int x1=ClusterToX(g_vprofiles[vi].ci_from);
        int x2=ClusterToX(g_vprofiles[vi].ci_to)+g_rdr_cw;
        if(x1<0) x1=0;
        if(mx>=x1&&mx<=x2) return vi;
    }
    return -1;
}

void HandleVPPanelClick(int mx, int my)
{
    if(g_vp_sel<0||g_vp_sel>=g_vp_count) return;
    int pw=290, ph=280;
    int px, py; VPPanelPos(px,py);

    // Fechar ×
    if(mx>=px+pw-22&&my>=py&&my<=py+30){g_vp_panel=false;g_vp_sel=-1;Redraw();return;}

    int cy=py+36; int lx=px+10;

    // Botões Volume / Delta (cy=py+36)
    if(my>=cy-1&&my<=cy+14)
    {
        if(mx>=px+90&&mx<=px+140){g_vprofiles[g_vp_sel].show_volume=!g_vprofiles[g_vp_sel].show_volume;Redraw();return;}
        if(mx>=px+144&&mx<=px+192){g_vprofiles[g_vp_sel].show_delta=!g_vprofiles[g_vp_sel].show_delta;Redraw();return;}
    }
    cy+=22+6; // cy=py+64: cores

    // Swatches de cor (cy=py+64)
    if(my>=cy+12&&my<=cy+26)
    {
        if(mx>=lx&&mx<=lx+28)      { OpenColorPicker(PICK_VP_BID, lx,      cy+28); return; }
        if(mx>=lx+50&&mx<=lx+78)   { OpenColorPicker(PICK_VP_ASK, lx+50,   cy+28); return; }
        if(mx>=lx+100&&mx<=lx+128) { OpenColorPicker(PICK_VP_POC, lx+100,  cy+28); return; }
    }
    cy+=34; // cy=py+98: checkboxes linha 1

    // Checkboxes: Soma / Espelhado / S/ clusters (cy=py+98)
    if(my>=cy&&my<=cy+12)
    {
        if(mx>=lx&&mx<=lx+12)       {g_vprofiles[g_vp_sel].volume_soma=!g_vprofiles[g_vp_sel].volume_soma;Redraw();return;}
        if(mx>=lx+80&&mx<=lx+92)    {g_vprofiles[g_vp_sel].delta_espelhado=!g_vprofiles[g_vp_sel].delta_espelhado;Redraw();return;}
        if(mx>=lx+188&&mx<=lx+200)  {g_vprofiles[g_vp_sel].sobre_clusters=!g_vprofiles[g_vp_sel].sobre_clusters;Redraw();return;}
    }
    cy+=22+6; // cy=py+126: POC/VA

    // POC / VA / stepper (cy=py+126)
    if(my>=cy&&my<=cy+12)
    {
        if(mx>=lx&&mx<=lx+12)       {g_vprofiles[g_vp_sel].show_poc=!g_vprofiles[g_vp_sel].show_poc;Redraw();return;}
        if(mx>=lx+60&&mx<=lx+72)    {g_vprofiles[g_vp_sel].show_va=!g_vprofiles[g_vp_sel].show_va;Redraw();return;}
        if(mx>=lx+152&&mx<=lx+164)  // VA% –
        {g_vprofiles[g_vp_sel].va_pct=MathMax(10,g_vprofiles[g_vp_sel].va_pct-5);Redraw();return;}
        if(mx>=lx+166&&mx<=lx+178)  // VA% +
        {g_vprofiles[g_vp_sel].va_pct=MathMin(100,g_vprofiles[g_vp_sel].va_pct+5);Redraw();return;}
    }
    cy+=22; // cy=py+148: VWAP

    if(my>=cy&&my<=cy+12&&mx>=lx&&mx<=lx+12)
    {g_vprofiles[g_vp_sel].show_vwap=!g_vprofiles[g_vp_sel].show_vwap;Redraw();return;}
    cy+=22+8; // cy=py+178: excluir

    if(mx>=px+10&&mx<=px+pw-10&&my>=cy&&my<=cy+24)
    {
        for(int i=g_vp_sel;i<g_vp_count-1;i++) g_vprofiles[i]=g_vprofiles[i+1];
        g_vp_count--;
        g_vp_panel=false; g_vp_sel=-1; Redraw(); return;
    }
}

//+------------------------------------------------------------------+
//| Ferramentas de desenho — seleção por Ctrl+drag                   |
//+------------------------------------------------------------------+
void HandleSelectionToolbar(int mx, int my)
{
    bool in_tb=(mx>=g_seltb_x && mx<g_seltb_x+100 && my>=g_seltb_y && my<g_seltb_y+26);
    if(!in_tb){ g_sel_ready=false; Redraw(); return; }

    int lx=mx-g_seltb_x;
    int sx1=MathMin(g_sel_x0,g_sel_x1), sy1=MathMin(g_sel_y0,g_sel_y1);
    int sx2=MathMax(g_sel_x0,g_sel_x1), sy2=MathMax(g_sel_y0,g_sel_y1);

    if(lx<37)  // Zona
    {
        if(g_zone_count<ZONE_MAX)
        {
            int ci_r=XToClusterIdx(sx2);  // lado direito = cluster mais novo
            int ci_l=XToClusterIdx(sx1);  // lado esquerdo = cluster mais antigo
            if(ci_r>ci_l){int t=ci_r;ci_r=ci_l;ci_l=t;}
            int zn=g_zone_count;
            g_zones[zn].price_high=YToPrice(sy1);
            g_zones[zn].price_low =YToPrice(sy2);
            g_zones[zn].ci_from=ci_r; g_zones[zn].ci_to=ci_l;
            g_zones[zn].border_clr=(color)0xFF4081;
            g_zones[zn].raio_dir=false; g_zones[zn].raio_esq=false;
            g_zones[zn].sobre_clusters=false; g_zones[zn].active=true;
            g_zone_count++;
        }
    }
    else if(lx<59)  // VP
    {
        if(g_vp_count<VP_MAX)
        {
            int ci_r=XToClusterIdx(sx2);
            int ci_l=XToClusterIdx(sx1);
            if(ci_r>ci_l){int t=ci_r;ci_r=ci_l;ci_l=t;}
            CalcVProfile(g_vprofiles[g_vp_count],ci_r,ci_l,YToPrice(sy1),YToPrice(sy2));
            g_vp_count++;
        }
    }
    else if(lx<78)  // Desfazer último
    {
        if(g_vp_count>0)   { g_vp_count--;   g_vprofiles[g_vp_count].active=false; }
        else if(g_zone_count>0){ g_zone_count--; g_zones[g_zone_count].active=false; }
    }
    // else ✕ → apenas fecha

    g_sel_ready=false;
    Redraw();
}

void DrawSelectionOverlay()
{
    if(!g_sel_drag && !g_sel_ready) return;

    int x1=MathMin(g_sel_x0,g_sel_x1), y1=MathMin(g_sel_y0,g_sel_y1);
    int x2=MathMax(g_sel_x0,g_sel_x1), y2=MathMax(g_sel_y0,g_sel_y1);

    // Borda verde da seleção
    g_canvas.Rectangle(x1,y1,x2,y2,Argb(0x00E676,255));

    if(!g_sel_ready) return;

    // Posiciona toolbar abaixo da seleção (ou acima se não cabe)
    int tbx=x1, tby=y2+6;
    if(tby+26>=g_canvas_h) tby=y1-30;
    if(tbx+100>=g_canvas_w) tbx=g_canvas_w-102;
    g_seltb_x=tbx; g_seltb_y=tby;

    // Fundo + borda da toolbar
    g_canvas.FillRectangle(tbx,tby,tbx+99,tby+25,Argb(0x0F1520,255));
    g_canvas.Rectangle(tbx,tby,tbx+99,tby+25,Argb(0x475569,255));

    // Separadores verticais
    for(int dy=3;dy<23;dy++)
    {
        g_canvas.PixelSet(tbx+36,tby+dy,Argb(0x475569,255));
        g_canvas.PixelSet(tbx+58,tby+dy,Argb(0x475569,255));
        g_canvas.PixelSet(tbx+77,tby+dy,Argb(0x475569,255));
    }

    // Rótulos dos botões
    g_canvas.FontSet("Arial Bold",9);
    g_canvas.TextOut(tbx+5, tby+6,"Zona",Argb(0xFF4081,255),TA_LEFT|TA_TOP);
    g_canvas.TextOut(tbx+41,tby+6,"VP",  Argb(0x00E676,255),TA_LEFT|TA_TOP);
    g_canvas.TextOut(tbx+62,tby+6,"↩",  Argb(0xF59E0B,255),TA_LEFT|TA_TOP);
    g_canvas.TextOut(tbx+82,tby+6,"✕",  Argb(0xEF4444,255),TA_LEFT|TA_TOP);
}

//+------------------------------------------------------------------+
//| Redraw                                                            |
//+------------------------------------------------------------------+
void Redraw()
{
    if(g_canvas_w<=0||g_canvas_h<=0) return;

    int cw      = MathMax(1, InpClusterWidth * g_zoom_h / 100);
    int col_gap = MathMax(2,  cw * 15 / 140);  // proporcional ao React (colGap=15*zoomH quando colWidth=140)
    int col_step= cw + col_gap;
    int axis_w  = 70;
    int chart_h = g_canvas_h - InpBottomPanel;

    g_canvas.Erase(Argb(InpColorBg,255));

    // Grade vertical sutil
    for(int x=0;x<g_canvas_w;x+=col_step)
        g_canvas.Line(x,0,x,chart_h,Argb(0x131820,255));

    // Separador painel inferior
    g_canvas.Line(0,chart_h,g_canvas_w,chart_h,Argb(0x1E293B,255));

    if(g_history_count==0&&!g_active_valid)
    {
        TxtOut(g_canvas_w/2-80,g_canvas_h/2,"Aguardando dados...",Argb(InpColorText,255),"Arial",14);
        g_canvas.Update(); return;
    }

    int chart_x1 = g_canvas_w - axis_w;
    int visible  = chart_x1 / col_step + 2;

    int last_idx  = g_history_count - 1 - g_scroll;
    int first_idx = MathMax(0, last_idx - visible + 1);

    // Range de preço dos clusters visíveis
    double pmax=-DBL_MAX, pmin=DBL_MAX;
    for(int ci=first_idx;ci<=last_idx;ci++)
    {
        if(g_history[HIdx(ci)].price_high>pmax)pmax=g_history[HIdx(ci)].price_high;
        if(g_history[HIdx(ci)].price_low <pmin)pmin=g_history[HIdx(ci)].price_low;
    }
    if(g_active_valid)
    {
        if(g_active.price_high>pmax)pmax=g_active.price_high;
        if(g_active.price_low <pmin)pmin=g_active.price_low;
    }
    if(pmax<=pmin){g_canvas.Update();return;}

    // Viewport vertical: SEMPRE max_levels * g_step — igual ao React (rowHeight=zoomV define o viewport)
    // Isso garante zoom out real: g_zoom_v pequeno → muitos níveis visíveis → clusters viram linhas
    {
        int max_levels=MathMax(4,(chart_h-4)/MathMax(g_zoom_v,1));
        double view_range=(double)max_levels*g_step;
        // Centro seguro: usa price_high/low do cluster ativo (nunca poc_price=0)
        double center=(g_active_valid&&g_active.price_high>0)
            ?(g_active.price_high+g_active.price_low)*0.5
            :(pmax+pmin)*0.5;
        pmin=center-view_range*0.5;
        pmax=center+view_range*0.5;
    }

    // Pan vertical: desloca o viewport pelo offset acumulado no drag
    pmin += g_pan_offset;
    pmax += g_pan_offset;
    g_last_prange = pmax - pmin;  // guarda para converter pixels → preço no drag handler

    // Salva estado do render — usado pelas ferramentas de desenho
    g_rdr_cw=cw; g_rdr_col_step=col_step; g_rdr_chart_x1=chart_x1; g_rdr_chart_h=chart_h;
    g_rdr_last_idx=last_idx; g_rdr_pmin=pmin; g_rdr_pmax=pmax;
    g_rdr_active_off=(g_active_valid&&g_scroll==0)?1:0;

    // Camada de fundo: zonas, VA overlay e VPs "atrás" — ANTES dos clusters
    DrawZoneFills(chart_h,pmin,pmax);
    DrawVAOverlays(chart_h,pmin,pmax);
    DrawVProfiles(chart_h,pmin,pmax,true);

    // max_side: escala global das barras do painel inferior
    double max_side=1;
    for(int ci=first_idx;ci<=last_idx;ci++)
    {
        double b=0,a=0;
        for(int li=0;li<g_history[HIdx(ci)].level_count;li++)
        { b+=g_history[HIdx(ci)].levels[li].bid; a+=g_history[HIdx(ci)].levels[li].ask; }
        if(b>max_side)max_side=b; if(a>max_side)max_side=a;
    }

    // Renderiza da direita para a esquerda (com margem direita de 3 colunas)
    int cx_right = chart_x1 - col_step * 3;
    if(g_active_valid && g_scroll==0)
    {
        CCalcPoc(g_active);
        DrawCluster(g_active, cx_right-cw, cw, chart_h, pmin, pmax, max_side, true);
        cx_right -= col_step;
    }
    for(int ci=last_idx; ci>=first_idx && cx_right>0; ci--)
    {
        DrawCluster(g_history[HIdx(ci)], cx_right-cw, cw, chart_h, pmin, pmax, max_side, false);
        cx_right -= col_step;
    }

    // Camada de frente: bordas das zonas + VPs "sobre clusters" — APÓS os clusters
    DrawZoneBorders(chart_h,pmin,pmax);
    DrawVProfiles(chart_h,pmin,pmax,false);

    DrawPriceAxis(chart_x1, chart_h, pmin, pmax);

    // Linha do preço atual (dashed ciano) — desenhada APÓS o eixo para não ser sobrescrita
    if(g_current_price>pmin && g_current_price<pmax)
    {
        double prange=pmax-pmin;
        int yc=chart_h-1-(int)((g_current_price-pmin)/prange*(chart_h-4));
        for(int x=0;x<chart_x1;x+=10)
            g_canvas.Line(x,yc,MathMin(x+6,chart_x1),yc,Argb(0x00E5FF,255));
        // tag na barra de preço
        g_canvas.FillRectangle(chart_x1+2,yc-8,g_canvas_w-2,yc+8,Argb(0x00E5FF,255));
        TxtOut(chart_x1+4,yc-5,DoubleToString(g_current_price,_Digits),Argb(InpColorBg,255),"Arial Bold",InpFontSize);
    }

    // Info atual (step/delta)
    string info="Step: "+DoubleToString(g_step_mult,1)+"x  |  Delta: "+DoubleToString(g_delta_max,0);
    TxtOut(40,5,info,Argb(InpColorText,255),"Arial",InpFontSize);

    DrawSelectionOverlay();
    DrawZonePanel();
    DrawVPPanel();
    DrawGearBtn();
    if(g_menu_open) DrawMenu();
    if(g_pick_open) DrawColorPicker();

    g_canvas.Update();
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    g_tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    if(g_tick_size<=0) g_tick_size=_Point;
    g_step_mult  = InpStepMultiplier;
    g_delta_max  = InpDeltaMax;
    g_step       = g_tick_size * g_step_mult;
    g_zoom_v     = InpLevelHeight;
    g_view_mode  = InpViewMode;
    g_close_mode = InpCloseMode;
    g_color_ask  = InpColorAsk;
    g_color_bid  = InpColorBid;
    g_color_poc  = InpColorPoc;
    g_form_step  = InpStepMultiplier;
    g_form_delta = InpDeltaMax;
    g_form_view  = (int)InpViewMode;
    g_form_mode  = InpCloseMode;

    ChartSetInteger(0,CHART_MODE,CHART_LINE);
    ChartSetInteger(0,CHART_COLOR_BACKGROUND,(color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_FOREGROUND,(color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_CHART_LINE,(color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_CHART_UP,  (color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_CHART_DOWN,(color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_BID,  (color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_ASK,  (color)InpColorBg);
    ChartSetInteger(0,CHART_COLOR_LAST, (color)InpColorBg);
    ChartSetInteger(0,CHART_SHOW_GRID,        false);
    ChartSetInteger(0,CHART_SHOW_VOLUMES,     false);
    ChartSetInteger(0,CHART_SHOW_OHLC,        false);
    ChartSetInteger(0,CHART_SHOW_BID_LINE,    false);
    ChartSetInteger(0,CHART_SHOW_ASK_LINE,    false);
    ChartSetInteger(0,CHART_SHOW_LAST_LINE,   false);
    ChartSetInteger(0,CHART_SHOW_PERIOD_SEP,  false);
    ChartSetInteger(0,CHART_CROSSHAIR_TOOL,   false);
    ChartSetInteger(0,CHART_SHOW_DATE_SCALE,  false);  // remove eixo de tempo no fundo
    ChartSetInteger(0,CHART_SHOW_PRICE_SCALE, false);  // remove eixo de preço nativo (usamos o nosso)
    ChartSetInteger(0,CHART_SHIFT,            false);  // remove margem direita nativa do MT5
    ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,1);
    ChartSetInteger(0,CHART_EVENT_MOUSE_WHEEL,1);
    ChartSetInteger(0,CHART_CONTEXT_MENU,false);

    g_canvas_w=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
    g_canvas_h=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);

    if(!g_canvas.CreateBitmapLabel(0,0,g_canvas_name,0,0,g_canvas_w,g_canvas_h,COLOR_FORMAT_XRGB_NOALPHA))
    { Print("TesteFootprint: erro canvas ",GetLastError()); return INIT_FAILED; }

    ObjectSetInteger(0,g_canvas_name,OBJPROP_ZORDER,10);
    ObjectSetInteger(0,g_canvas_name,OBJPROP_BACK,false);
    ObjectSetInteger(0,g_canvas_name,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,g_canvas_name,OBJPROP_SELECTED,false);
    ObjectSetInteger(0,g_canvas_name,OBJPROP_HIDDEN,true);
    ObjectSetInteger(0,g_canvas_name,OBJPROP_XDISTANCE,0);
    ObjectSetInteger(0,g_canvas_name,OBJPROP_YDISTANCE,0);

    ActiveReset();
    LoadHistory();
    Redraw();
    EventSetTimer(1);
    return INIT_SUCCEEDED;
}

void OnTimer()  { ResizeCanvas(); Redraw(); }

void OnDeinit(const int reason)
{
    EventKillTimer();
    g_canvas.Destroy();
    ObjectDelete(0,g_canvas_name);
    ChartSetInteger(0,CHART_MODE,CHART_CANDLES);
    ChartSetInteger(0,CHART_SHOW_GRID,true);
    ChartSetInteger(0,CHART_SHOW_OHLC,true);
    ChartSetInteger(0,CHART_SHOW_BID_LINE,true);
    ChartSetInteger(0,CHART_SHOW_PERIOD_SEP,true);
    ChartSetInteger(0,CHART_CROSSHAIR_TOOL,true);
    ChartSetInteger(0,CHART_CONTEXT_MENU,true);
    ChartRedraw(0);
}

void OnTick()
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol,tick)) return;
    if(tick.time_msc<=(long)g_last_tick_msc) return;
    g_last_tick_msc=tick.time_msc;
    double p,v; bool b;
    if(ParseTick(tick,p,v,b)) ProcessTick(p,v,b,tick.time_msc);
    ResizeCanvas();
    ulong now=GetTickCount64();
    if(now-g_last_draw_msc>=50){g_last_draw_msc=now;Redraw();}
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
    if(id==CHARTEVENT_CHART_CHANGE){ResizeCanvas();Redraw();return;}

    //--- Teclado ---
    if(id==CHARTEVENT_KEYDOWN)
    {
        if(lparam==37){g_scroll++;Redraw();}                                         // ← scroll
        if(lparam==39){g_scroll=MathMax(0,g_scroll-1);Redraw();}                    // → scroll
        if(lparam==36){g_scroll=0;Redraw();}                                         // Home
        if(lparam==38){g_zoom_v=MathMin(200,g_zoom_v+2);Redraw();}                  // ↑ zoom V+
        if(lparam==40){g_zoom_v=MathMax(1, g_zoom_v-2);Redraw();}                   // ↓ zoom V-
        if(lparam==219){g_step_mult=MathMax(0.5,g_step_mult/2.0);Reload();return;}  // [ step÷2
        if(lparam==221){g_step_mult=MathMin(200,g_step_mult*2.0);Reload();return;}  // ] step×2
        if(lparam==188){g_delta_max=MathMax(100,g_delta_max-200);Reload();return;}  // , delta-200
        if(lparam==190){g_delta_max=g_delta_max+200;Reload();return;}               // . delta+200
        return;
    }

    //--- Mouse Move ---
    if(id==CHARTEVENT_MOUSE_MOVE)
    {
        int mx=(int)lparam, my=(int)dparam;
        bool btn  = ((int)sparam&1)!=0;
        bool ctrl = (TerminalInfoInteger(TERMINAL_KEYSTATE_CONTROL)&0x8000)!=0;
        bool is_sel = ctrl && btn;  // Ctrl+left-drag = seleção de área
        int chart_h=g_canvas_h-InpBottomPanel;
        int axis_x0=g_canvas_w-70;

        // Detecção de click: botão acabou de ser pressionado
        bool just_pressed=(!g_prev_btn&&btn);
        g_prev_btn=btn;

        bool in_gear=(mx>=5&&mx<=33&&my>=8&&my<=36);
        bool in_menu=(g_menu_open&&mx>=MNU_X&&mx<=MNU_X+MNU_W&&my>=MNU_Y&&my<=MNU_Y+450);

        // Hit-test painel de zona
        int zpx=0,zpy=0; if(g_zone_panel&&g_zone_sel>=0) ZonePanelPos(zpx,zpy);
        bool in_zone_panel=(g_zone_panel&&mx>=zpx&&mx<=zpx+244&&my>=zpy&&my<=zpy+205);
        // Hit-test painel de VP
        int vppx=0,vppy=0; if(g_vp_panel&&g_vp_sel>=0) VPPanelPos(vppx,vppy);
        bool in_vp_panel=(g_vp_panel&&mx>=vppx&&mx<=vppx+290&&my>=vppy&&my<=vppy+280);

        // Color picker: prioridade máxima
        bool in_color_picker=(g_pick_open&&mx>=g_pick_px&&mx<=g_pick_px+PICK_W&&my>=g_pick_py&&my<=g_pick_py+PICK_H);
        if(g_pick_open)
        {
            if(just_pressed && in_color_picker){ HandleColorPickerClick(mx,my); return; }
            if(just_pressed && !in_color_picker){ g_pick_open=false; Redraw(); }
            if(in_color_picker) return;   // absorve hover
        }

        // Rastreamento do botão direito
        bool btn_r=((int)sparam&2)!=0;
        bool just_pressed_r=(!g_rbtn_prev && btn_r);
        g_rbtn_prev=btn_r;

        // ── Right-drag de seleção em andamento ──
        if(g_sel_drag && g_sel_is_right)
        {
            if(!btn_r)
            {
                g_sel_drag=false;
                if(MathAbs(g_sel_x1-g_sel_x0)>8||MathAbs(g_sel_y1-g_sel_y0)>8)
                    g_sel_ready=true;
                Redraw(); return;
            }
            if(mx!=g_sel_x1||my!=g_sel_y1){ g_sel_x1=mx; g_sel_y1=my; Redraw(); }
            return;
        }

        // ── Ctrl+left-drag de seleção em andamento ──
        if(g_sel_drag && !g_sel_is_right)
        {
            if(!is_sel)
            {
                g_sel_drag=false;
                if(MathAbs(g_sel_x1-g_sel_x0)>8||MathAbs(g_sel_y1-g_sel_y0)>8)
                    g_sel_ready=true;
                Redraw(); return;
            }
            if(mx!=g_sel_x1||my!=g_sel_y1){ g_sel_x1=mx; g_sel_y1=my; Redraw(); }
            return;
        }

        // ── Right-click-wait: pressionado sobre ferramenta, aguardando click vs drag ──
        if(g_rclick_wait)
        {
            if(!btn_r)
            {
                // Solto sem arrastar → abre config da ferramenta
                g_rclick_wait=false;
                if(g_rclick_vi>=0)
                { g_zone_panel=false; g_vp_sel=g_rclick_vi; g_vp_panel=true; g_vppx=g_rclick_xi+12; g_vppy=g_rclick_yi+12; Redraw(); }
                else if(g_rclick_zi>=0)
                { g_vp_panel=false; g_zone_sel=g_rclick_zi; g_zone_panel=true; g_zpx=g_rclick_xi+12; g_zpy=g_rclick_yi+12; Redraw(); }
                return;
            }
            if(MathAbs(mx-g_rclick_xi)>10||MathAbs(my-g_rclick_yi)>10)
            {
                // Arrastou → converte em drag de seleção
                g_rclick_wait=false;
                g_sel_drag=true; g_sel_is_right=true;
                g_sel_x0=g_rclick_xi; g_sel_y0=g_rclick_yi;
                g_sel_x1=mx; g_sel_y1=my; g_sel_ready=false;
                Redraw();
            }
            return;
        }

        // ── Nova pressão do botão direito ──
        if(just_pressed_r && !in_zone_panel && !in_vp_panel && !in_gear && !in_menu)
        {
            int vi=HitTestVP(mx,my);
            int zi=(vi<0)?HitTestZone(mx,my):-1;
            g_rclick_xi=mx; g_rclick_yi=my; g_rclick_vi=vi; g_rclick_zi=zi;
            if(vi>=0||zi>=0)
                g_rclick_wait=true;       // sobre ferramenta → esperar ver se é click ou drag
            else
            { g_sel_drag=true; g_sel_is_right=true; g_sel_x0=mx; g_sel_y0=my; g_sel_x1=mx; g_sel_y1=my; g_sel_ready=false; }
            return;
        }

        // ── Ctrl+left-drag start ──
        if(is_sel && !g_sel_drag)
        {
            g_sel_drag=true; g_sel_is_right=false;
            g_sel_x0=mx; g_sel_y0=my; g_sel_x1=mx; g_sel_y1=my; g_sel_ready=false;
            return;
        }

        if(just_pressed&&g_sel_ready)           { HandleSelectionToolbar(mx,my); return; }
        if(just_pressed&&in_zone_panel)          { HandleZonePanelClick(mx,my); return; }
        if(just_pressed&&in_vp_panel)            { HandleVPPanelClick(mx,my); return; }
        if(just_pressed&&(in_gear||in_menu))     { HandleMenuClick(mx,my); return; }
        if(in_zone_panel||in_vp_panel||in_gear||in_menu) return;

        // Clique esquerdo fora fecha painéis abertos
        if(just_pressed&&g_zone_panel){ g_zone_panel=false; g_zone_sel=-1; Redraw(); }
        if(just_pressed&&g_vp_panel)  { g_vp_panel=false;  g_vp_sel=-1;   Redraw(); }

        // Left-click em zona ou VP → apenas seleciona (destaque visual, sem abrir painel)
        if(just_pressed&&!ctrl)
        {
            int vi=HitTestVP(mx,my);
            if(vi>=0){ g_vp_sel=vi; g_vp_panel=false; Redraw(); return; }
            int zi=HitTestZone(mx,my);
            if(zi>=0){ g_zone_sel=zi; g_zone_panel=false; Redraw(); return; }
            // Clique em vazio → deseleciona
            if(g_vp_sel>=0||g_zone_sel>=0){ g_vp_sel=-1; g_zone_sel=-1; Redraw(); }
        }

        if(!btn)
        {
            g_vaxis_drag=false;
            g_haxis_drag=false;
            g_pan_drag=false;
            return;
        }

        // Pan vertical: arrastar área principal (esquerda da barra de preço, acima do painel)
        if(!g_vaxis_drag && !g_haxis_drag && !ctrl && mx<axis_x0 && my>=0 && my<chart_h)
        {
            if(!g_pan_drag)
                { g_pan_drag=true; g_pan_y0=my; g_pan_off0=g_pan_offset; return; }
            int dy=my-g_pan_y0;
            double price_per_px=g_last_prange/MathMax(1,chart_h-4);
            g_pan_offset=g_pan_off0+(double)dy*price_per_px;  // dy>0=arrastar baixo=pmin/pmax sobem=conteúdo desce
            Redraw(); return;
        }

        // Drag na barra de preço (direita) → zoom vertical
        if(!g_haxis_drag && mx>=axis_x0 && my>=0 && my<chart_h)
        {
            if(!g_vaxis_drag)
                { g_vaxis_drag=true; g_vdrag_y0=my; g_vdrag_z0=g_zoom_v; return; }
            int nz=MathMax(1,MathMin(200,(int)(g_vdrag_z0*(1.0+(g_vdrag_y0-my)*0.01))));
            if(nz!=g_zoom_v){g_zoom_v=nz;Redraw();}
            return;
        }

        // Drag no painel inferior → zoom horizontal (igual React timeAxis drag)
        if(!g_vaxis_drag && my>=chart_h && mx<axis_x0)
        {
            if(!g_haxis_drag)
                { g_haxis_drag=true; g_hdrag_x0=mx; g_hdrag_zh0=g_zoom_h; return; }
            double factor=1.0+(mx-g_hdrag_x0)*0.008;
            int nz=MathMax(1,MathMin(800,(int)((double)g_hdrag_zh0*factor)));
            if(nz!=g_zoom_h){g_zoom_h=nz;Redraw();}
            return;
        }

        return;
    }

    //--- Mouse Wheel ---
    if(id==CHARTEVENT_MOUSE_WHEEL)
    {
        // sparam = "flags;x;y;delta"
        string parts[]; int n=StringSplit(sparam,';',parts);
        int wheel=(n>=4)?(int)StringToInteger(parts[3]):((int)dparam>0?120:-120);

        bool ctrl=(TerminalInfoInteger(TERMINAL_KEYSTATE_CONTROL)&0x8000)!=0;
        if(ctrl)
        {
            // Ctrl+scroll = zoom horizontal
            if(wheel>0) g_zoom_h=MathMin(800,g_zoom_h+10);
            else        g_zoom_h=MathMax(1,  g_zoom_h-10);
        }
        else
        {
            // Scroll normal = navegar clusters L/R
            if(wheel>0) g_scroll=MathMax(0,g_scroll-3);
            else        g_scroll+=3;
            g_scroll=MathMax(0,MathMin(g_scroll,g_history_count-1));
        }
        Redraw(); return;
    }
}
