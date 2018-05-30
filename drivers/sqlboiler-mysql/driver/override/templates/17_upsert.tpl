{{- $tableNameSingular := .Table.Name | singular | titleCase -}}
{{- $varNameSingular := .Table.Name | singular | camelCase -}}
{{- $schemaTable := .Table.Name | .SchemaTable}}
{{if .AddGlobal -}}
// UpsertG attempts an insert, and does an update or ignore on conflict.
func (o *{{$tableNameSingular}}) UpsertG({{if not .NoContext}}ctx context.Context, {{end -}} updateColumns []string, whitelist ...string) error {
	return o.Upsert({{if .NoContext}}boil.GetDB(){{else}}ctx, boil.GetContextDB(){{end}}, updateColumns, whitelist...)
}

{{end -}}

{{if and .AddGlobal .AddPanic -}}
// UpsertGP attempts an insert, and does an update or ignore on conflict. Panics on error.
func (o *{{$tableNameSingular}}) UpsertGP({{if not .NoContext}}ctx context.Context, {{end -}} updateColumns []string, whitelist ...string) {
	if err := o.Upsert({{if .NoContext}}boil.GetDB(){{else}}ctx, boil.GetContextDB(){{end}}, updateColumns, whitelist...); err != nil {
		panic(boil.WrapErr(err))
	}
}

{{end -}}

{{if .AddPanic -}}
// UpsertP attempts an insert using an executor, and does an update or ignore on conflict.
// UpsertP panics on error.
func (o *{{$tableNameSingular}}) UpsertP({{if .NoContext}}exec boil.Executor{{else}}ctx context.Context, exec boil.ContextExecutor{{end}}, updateColumns []string, whitelist ...string) {
	if err := o.Upsert({{if not .NoContext}}ctx, {{end -}} exec, updateColumns, whitelist...); err != nil {
		panic(boil.WrapErr(err))
	}
}

{{end -}}

// Upsert attempts an insert using an executor, and does an update or ignore on conflict.
func (o *{{$tableNameSingular}}) Upsert({{if .NoContext}}exec boil.Executor{{else}}ctx context.Context, exec boil.ContextExecutor{{end}}, updateColumns []string, whitelist ...string) error {
	if o == nil {
		return errors.New("{{.PkgName}}: no {{.Table.Name}} provided for upsert")
	}

	{{- template "timestamp_upsert_helper" . }}

	{{if not .NoHooks -}}
	if err := o.doBeforeUpsertHooks({{if not .NoContext}}ctx, {{end -}} exec); err != nil {
		return err
	}
	{{- end}}

	nzDefaults := queries.NonZeroDefaultSet({{$varNameSingular}}ColumnsWithDefault, o)

	// Build cache key in-line uglily - mysql vs psql problems
	buf := strmangle.GetBuffer()
	for _, c := range updateColumns {
		buf.WriteString(c)
	}
	buf.WriteByte('.')
	for _, c := range whitelist {
		buf.WriteString(c)
	}
	buf.WriteByte('.')
	for _, c := range nzDefaults {
		buf.WriteString(c)
	}
	key := buf.String()
	strmangle.PutBuffer(buf)

	{{$varNameSingular}}UpsertCacheMut.RLock()
	cache, cached := {{$varNameSingular}}UpsertCache[key]
	{{$varNameSingular}}UpsertCacheMut.RUnlock()

	var err error

	if !cached {
		insert, ret := strmangle.InsertColumnSet(
			{{$varNameSingular}}Columns,
			{{$varNameSingular}}ColumnsWithDefault,
			{{$varNameSingular}}ColumnsWithoutDefault,
			nzDefaults,
			whitelist,
		)
		update := strmangle.UpdateColumnSet(
			{{$varNameSingular}}Columns,
			{{$varNameSingular}}PrimaryKeyColumns,
			updateColumns,
		)

		if len(update) == 0 {
			return errors.New("{{.PkgName}}: unable to upsert {{.Table.Name}}, could not build update column list")
		}

		cache.query = buildUpsertQueryMySQL(dialect, "{{.Table.Name}}", update, insert)
		cache.retQuery = fmt.Sprintf(
			"SELECT %s FROM {{.LQ}}{{.Table.Name}}{{.RQ}} WHERE {{whereClause .LQ .RQ 0 .Table.PKey.Columns}}",
			strings.Join(strmangle.IdentQuoteSlice(dialect.LQ, dialect.RQ, ret), ","),
		)

		cache.valueMapping, err = queries.BindMapping({{$varNameSingular}}Type, {{$varNameSingular}}Mapping, insert)
		if err != nil {
			return err
		}
		if len(ret) != 0 {
			cache.retMapping, err = queries.BindMapping({{$varNameSingular}}Type, {{$varNameSingular}}Mapping, ret)
			if err != nil {
				return err
			}
		}
	}

	value := reflect.Indirect(reflect.ValueOf(o))
	vals := queries.ValuesFromMapping(value, cache.valueMapping)
	var returns []interface{}
	if len(cache.retMapping) != 0 {
		returns = queries.PtrsFromMapping(value, cache.retMapping)
	}

	if boil.DebugMode {
		fmt.Fprintln(boil.DebugWriter, cache.query)
		fmt.Fprintln(boil.DebugWriter, vals)
	}

	{{$canLastInsertID := .Table.CanLastInsertID -}}
	{{if $canLastInsertID -}}
		{{if .NoContext -}}
	result, err := exec.Exec(cache.query, vals...)
		{{else -}}
	result, err := exec.ExecContext(ctx, cache.query, vals...)
		{{end -}}
	{{else -}}
		{{if .NoContext -}}
	_, err = exec.Exec(cache.query, vals...)
		{{else -}}
	_, err = exec.ExecContext(ctx, cache.query, vals...)
		{{end -}}
	{{- end}}
	if err != nil {
		return errors.Wrap(err, "{{.PkgName}}: unable to upsert for {{.Table.Name}}")
	}

	{{if $canLastInsertID -}}
	var lastID int64
	{{- end}}
	var identifierCols []interface{}

	if len(cache.retMapping) == 0 {
		goto CacheNoHooks
	}

	{{if $canLastInsertID -}}
	lastID, err = result.LastInsertId()
	if err != nil {
		return ErrSyncFail
	}

	{{$colName := index .Table.PKey.Columns 0 -}}
	{{- $col := .Table.GetColumn $colName -}}
	{{- $colTitled := $colName | titleCase}}
	o.{{$colTitled}} = {{$col.Type}}(lastID)
	if lastID != 0 && len(cache.retMapping) == 1 && cache.retMapping[0] == {{$varNameSingular}}Mapping["{{$colTitled}}"] {
		goto CacheNoHooks
	}
	{{- end}}

	identifierCols = []interface{}{
		{{range .Table.PKey.Columns -}}
		o.{{. | titleCase}},
		{{end -}}
	}

	if boil.DebugMode {
		fmt.Fprintln(boil.DebugWriter, cache.retQuery)
		fmt.Fprintln(boil.DebugWriter, identifierCols...)
	}

	{{if .NoContext -}}
	err = exec.QueryRow(cache.retQuery, identifierCols...).Scan(returns...)
	{{else -}}
	err = exec.QueryRowContext(ctx, cache.retQuery, identifierCols...).Scan(returns...)
	{{end -}}
	if err != nil {
		return errors.Wrap(err, "{{.PkgName}}: unable to populate default values for {{.Table.Name}}")
	}

CacheNoHooks:
	if !cached {
		{{$varNameSingular}}UpsertCacheMut.Lock()
		{{$varNameSingular}}UpsertCache[key] = cache
		{{$varNameSingular}}UpsertCacheMut.Unlock()
	}

	{{if not .NoHooks -}}
	return o.doAfterUpsertHooks({{if not .NoContext}}ctx, {{end -}} exec)
	{{- else -}}
	return nil
	{{- end}}
}