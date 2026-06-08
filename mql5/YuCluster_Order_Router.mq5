//+------------------------------------------------------------------+
//|                                     YuCluster_Order_Router.mq5   |
//|                                    Integração Python <-> CTrade  |
//+------------------------------------------------------------------+
#property description "Roteador de Execução Institucional OCO"
#property version   "1.00"

// 1. Incluindo a Biblioteca CTrade para facilitar o envio de ordens
#include <Trade\Trade.mqh>

// Instanciando o objeto de trade
CTrade trade;

//+------------------------------------------------------------------+
//| VARIÁVEIS DE ENTRADA (ISOLANDO O FATOR PSICOLÓGICO)              |
//+------------------------------------------------------------------+
input group "=== Gestão de Risco OCO ==="
input double   InpLote        = 1.0;     // Lote (Tamanho da Posição)
input int      InpStopLoss    = 150;     // Stop Loss (em pontos)
input int      InpTakeProfit  = 300;     // Take Profit (em pontos)

input group "=== Configurações do Robô ==="
input ulong    InpMagicNumber = 123456;  // Número Mágico (CPF do Robô)

//+------------------------------------------------------------------+
//| FUNÇÃO DE INICIALIZAÇÃO                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Configura o Número Mágico para que o EA gerencie apenas as próprias ordens
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // Define o desvio máximo aceitável (Slippage)
   trade.SetDeviationInPoints(5);
   
   Print("Roteador Institucional Iniciado. Fator emocional desativado.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| FUNÇÃO DE EXECUÇÃO DE COMPRA A MERCADO                           |
//+------------------------------------------------------------------+
void ExecutarCompra()
  {
   // Atualiza os dados de preço de mercado (Tick)
   MqlTick tick;
   SymbolInfoTick(_Symbol, tick);
   
   // Calcula os níveis de Stop Loss e Take Profit engessados
   double sl = tick.ask - (InpStopLoss * _Point);
   double tp = tick.ask + (InpTakeProfit * _Point);
   
   // Normaliza as casas decimais de acordo com o ativo (Tick Size)
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   
   // Envia a ordem a mercado instantaneamente
   if(trade.Buy(InpLote, _Symbol, tick.ask, sl, tp, "YuCluster: Compra na POC"))
     {
      Print("Compra executada com sucesso! SL e TP na pedra.");
     }
   else
     {
      Print("Erro ao executar compra. Código: ", trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| FUNÇÃO DE EXECUÇÃO DE VENDA A MERCADO                            |
//+------------------------------------------------------------------+
void ExecutarVenda()
  {
   // Atualiza os dados de preço de mercado (Tick)
   MqlTick tick;
   SymbolInfoTick(_Symbol, tick);
   
   // Calcula os níveis de Stop Loss e Take Profit engessados (invertido para venda)
   double sl = tick.bid + (InpStopLoss * _Point);
   double tp = tick.bid - (InpTakeProfit * _Point);
   
   // Normaliza os cálculos
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   
   // Envia a ordem a mercado instantaneamente
   if(trade.Sell(InpLote, _Symbol, tick.bid, sl, tp, "YuCluster: Venda no Imbalance"))
     {
      Print("Venda executada com sucesso! SL e TP na pedra.");
     }
   else
     {
      Print("Erro ao executar venda. Código: ", trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| LAÇO PRINCIPAL (Aguardando o gatilho do Python)                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Aqui o EA fica "escutando" variáveis globais do terminal ou requisições
   // que o nosso backend em Python enviará ao detectar o botão clicado no Painel Web.
   
   if(GlobalVariableGet("SINAL_PYTHON_COMPRA") == 1)
     {
      ExecutarCompra();
      GlobalVariableSet("SINAL_PYTHON_COMPRA", 0); // Reseta o sinal
     }
     
   if(GlobalVariableGet("SINAL_PYTHON_VENDA") == 1)
     {
      ExecutarVenda();
      GlobalVariableSet("SINAL_PYTHON_VENDA", 0); // Reseta o sinal
     }
  }
