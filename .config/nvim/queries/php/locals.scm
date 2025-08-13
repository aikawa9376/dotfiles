;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Definitions
;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 変数への代入
; 例: $variable = "value";
; これが元の投稿で指摘されていた最も重要な修正点です。
(assignment_expression
  left: (variable_name (name) @local.definition.var))

; foreachループで定義されるキーと値
; 例: foreach ($array as $key => $value)
(foreach_statement
  (pair
    (variable_name (name) @local.definition.var)
    (variable_name (name) @local.definition.var)))
(foreach_statement
  (variable_name (name) @local.definition.var))

; catch節で定義される例外変数
; 例: catch (Exception $e)
(catch_clause
  (variable_name (name) @local.definition.var))

; static変数の宣言
; 例: static $count = 0;
(static_variable_declaration
  (variable_name (name) @local.definition.var))

; 関数やメソッドの仮引数
; 例: function myFunction($param1, $param2)
(simple_parameter
  (variable_name (name) @local.definition.parameter))

;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; References
;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 上記の定義に当てはまらない、すべての変数使用
; 例: echo $variable;
(variable_name (name) @local.reference.var)
