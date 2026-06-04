# SKILL.md — YuClusters Local

## Regras de Cálculo (NÃO ALTERAR)

1. Imbalance diagonal BUY no nível i: ask_vol[i] >= R * bid_vol[i-1]  (compara com nível ABAIXO)
2. Imbalance diagonal SELL no nível i: bid_vol[i] >= R * ask_vol[i+1] (compara com nível ACIMA)
3. POC = nível com MAIOR (ask_vol + bid_vol) dentro do cluster
4. Delta do cluster = soma de todos os delta[i] de todos os níveis
5. Stacked = mínimo de STACKED_MIN_COUNT níveis consecutivos com imbalance na MESMA direção

## Regras de Implementação

- NUNCA misturar lógica de agregação com lógica de UI
- NUNCA recalcular clusters históricos fechados
- SEMPRE usar tick_size do MT5 como granularidade mínima de nível de preço
- Conexão MT5 SEMPRE via lib oficial `MetaTrader5`, nunca via subprocess ou API REST externa
