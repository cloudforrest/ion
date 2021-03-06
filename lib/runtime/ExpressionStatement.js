void (function(){var _ion_runtime_ExpressionStatement_ = function(module,exports,require){'use strict';
var ion = require('../'), _ref;
_ref = require('./');
var Factory = _ref.Factory;
var Statement = _ref.Statement;
var ExpressionStatement = ion.defineClass({
        name: 'ExpressionStatement',
        properties: {
            activate: function () {
                ExpressionStatement.super.prototype.activate.apply(this, arguments);
                this.runtimeExpression = this.runtimeExpression != null ? this.runtimeExpression : this.context.createRuntime(this.expression);
                this.unobserve = this.runtimeExpression.observe(this.runtimeExpressionObserver = this.runtimeExpressionObserver != null ? this.runtimeExpressionObserver : ion.bind(function (value) {
                    if (this.expressionValue !== value) {
                        this.expressionValue = value;
                        this._remove != null ? this._remove() : void 0;
                        this._remove = null;
                        if (this.context.output != null && value !== void 0) {
                            try {
                                this._remove = this.context.insert(value, this.order, this);
                            } catch (e) {
                                console.warn('Error adding ' + value + ' to ' + this.context.output + ':  (' + Factory.toCode(this.callee) + ') (' + this.loc.start.source + ':' + this.loc.start.line + ':' + (this.loc.start.column + 1) + ')');
                                console.error(e);
                            }
                        }
                    }
                }, this));
            },
            deactivate: function () {
                ExpressionStatement.super.prototype.deactivate.apply(this, arguments);
                this.runtimeExpressionObserver != null ? this.runtimeExpressionObserver(void 0) : void 0;
                this.unobserve != null ? this.unobserve() : void 0;
                this.unobserve = null;
                this._remove != null ? this._remove() : void 0;
                this._remove = null;
            }
        }
    }, Statement);
module.exports = exports = ExpressionStatement;
  }
  if (typeof require === 'function') {
    if (require.register)
      require.register('ion/runtime/ExpressionStatement',_ion_runtime_ExpressionStatement_);
    else
      _ion_runtime_ExpressionStatement_.call(this, module, exports, require);
  }
  else {
    _ion_runtime_ExpressionStatement_.call(this);
  }
}).call(this)