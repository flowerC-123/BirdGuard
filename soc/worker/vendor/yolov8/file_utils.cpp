#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "log.h"

#define MAX_TEXT_LINE_LENGTH 1024

int read_data_from_file(const char *path, char **out_data) {
    FILE *fp = fopen(path, "rb");
    if (fp == NULL) {
        logPrint(LOG_ERROR, "fopen %s fail!", path);
        return -1;
    }
    fseek(fp, 0, SEEK_END);
    int file_size = ftell(fp);
    char *data = (char *)malloc(file_size + 1);
    if (data == NULL) {
        logPrint(LOG_ERROR, "malloc fail, size=%d", file_size + 1);
        fclose(fp);
        return -1;
    }
    data[file_size] = 0;
    fseek(fp, 0, SEEK_SET);
    if (file_size != (int)fread(data, 1, file_size, fp)) {
        logPrint(LOG_ERROR, "fread %s fail!", path);
        free(data);
        fclose(fp);
        return -1;
    }
    fclose(fp);
    *out_data = data;
    return file_size;
}

int write_data_to_file(const char *path, const char *data, unsigned int size) {
    FILE *fp = fopen(path, "w");
    if (fp == NULL) {
        logPrint(LOG_ERROR, "open error: %s", path);
        return -1;
    }

    fwrite(data, 1, size, fp);
    fflush(fp);

    fclose(fp);
    return 0;
}

int count_lines(FILE *file) {
    int count = 0;
    char ch;

    while (!feof(file)) {
        ch = fgetc(file);
        if (ch == '\n') {
            count++;
        }
    }
    count += 1;

    rewind(file);
    return count;
}

char **read_lines_from_file(const char *filename, int *line_count) {
    FILE *file = fopen(filename, "r");
    if (file == NULL) {
        logPrint(LOG_ERROR, "Failed to open the file: %s", filename);
        return NULL;
    }

    int num_lines = count_lines(file);
    char **lines = (char **)malloc(num_lines * sizeof(char *));
    if (lines == NULL) {
        logPrint(LOG_ERROR, "malloc lines fail, num_lines=%d", num_lines);
        fclose(file);
        return NULL;
    }
    memset(lines, 0, num_lines * sizeof(char *));

    char buffer[MAX_TEXT_LINE_LENGTH];
    int line_index = 0;

    while (fgets(buffer, sizeof(buffer), file) != NULL) {
        buffer[strcspn(buffer, "\n")] = '\0';

        lines[line_index] = (char *)malloc(strlen(buffer) + 1);
        if (lines[line_index] == NULL) {
            logPrint(LOG_ERROR, "malloc line fail, line_index=%d", line_index);
            break;
        }
        strcpy(lines[line_index], buffer);

        line_index++;
    }

    fclose(file);

    *line_count = num_lines;
    return lines;
}

void free_lines(char **lines, int line_count) {
    for (int i = 0; i < line_count; i++) {
        if (lines[i] != NULL) {
            free(lines[i]);
        }
    }
    free(lines);
}
