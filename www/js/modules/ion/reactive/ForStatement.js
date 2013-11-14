(function(){require.register('ion/reactive/ForStatement',function(module,exports,require){// Generated by CoffeeScript 1.6.3
(function() {
  var Context, ForStatement, Map, Operation, Statement, core, _ref,
    __hasProp = {}.hasOwnProperty,
    __extends = function ___extends(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

  Operation = require('./Operation');

  Statement = require('./Statement');

  Context = require('./Context');

  core = require('../core');

  Map = require('../ForEachMap');

  module.exports = ForStatement = (function(_super) {
    __extends(ForStatement, _super);

    function ForStatement() {
      _ref = ForStatement.__super__.constructor.apply(this, arguments);
      return _ref;
    }

    ForStatement.prototype.activate = function _activate() {
      var key, value, _ref1;
      ForStatement.__super__.activate.call(this);
      if (this.statementMap == null) {
        this.statementMap = new Map;
      }
      _ref1 = this.context.input;
      for (key in _ref1) {
        value = _ref1[key];
        this.addItem(value);
      }
      return core.observe(this.context.input, this.applyChanges.bind(this));
    };

    ForStatement.prototype.applyChanges = function _applyChanges(changes) {
      var change, current, key, maybeRemove, newValue, value, _i, _len, _ref1,
        _this = this;
      current = new Set;
      _ref1 = this.context.input;
      for (key in _ref1) {
        value = _ref1[key];
        current.add(value);
      }
      maybeRemove = new Map;
      for (_i = 0, _len = changes.length; _i < _len; _i++) {
        change = changes[_i];
        if (!(change.name !== 'length')) {
          continue;
        }
        if (change.oldValue != null) {
          maybeRemove.set(change.oldValue, change.oldValue);
        }
        newValue = this.context.input[change.name];
        if (newValue != null) {
          this.addItem(newValue);
        }
      }
      return maybeRemove.forEach(function(key, value) {
        if (!current.has(value)) {
          return _this.removeItem(value);
        }
      });
    };

    ForStatement.prototype.addItem = function _addItem(item) {
      var newContext, statement;
      if (!this.statementMap.has(item)) {
        newContext = new Context(item, this.context.output, this.context, this.context.additions);
        statement = Operation.createRuntime(newContext, this.args[1]);
        this.statementMap.set(item, statement);
        return statement.activate();
      }
    };

    ForStatement.prototype.removeItem = function _removeItem(item) {
      var statement;
      statement = this.statementMap.get(item);
      if (statement != null) {
        statement.deactivate();
        return this.statementMap["delete"](item);
      }
    };

    ForStatement.prototype.deactivate = function _deactivate() {
      var _this = this;
      ForStatement.__super__.deactivate.call(this);
      this.statementMap.forEach(function(item, statement) {
        return _this.removeItem(item);
      });
      return this.statementMap.clear();
    };

    ForStatement.prototype.dispose = function _dispose() {
      return ForStatement.__super__.dispose.call(this);
    };

    return ForStatement;

  })(Statement);

  module.exports.test = function _test(done) {
    var a, ast, context, input, output;
    input = [1, 2, 3, 4];
    output = [];
    context = new Context(input, output);
    ast = require('../').parseStatement("for\n    . * 2");
    a = Operation.createRuntime(context, ast);
    a.activate();
    input.remove(2);
    input.add(5);
    return Object.observe(output, function(changes) {
      if (Object.equal(output, [2, 6, 8, 10])) {
        a.deactivate();
        if (!output.length === 0) {
          return done("output should have been empty: " + (JSON.stringify(output)));
        } else {
          return done();
        }
      }
    });
  };

}).call(this);

})})()